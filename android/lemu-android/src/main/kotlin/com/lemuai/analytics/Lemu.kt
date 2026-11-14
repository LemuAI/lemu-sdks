package com.lemuai.analytics

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import com.lemuai.analytics.core.FileStorage
import com.lemuai.analytics.core.InMemoryStorage
import com.lemuai.analytics.core.LemuClient
import com.lemuai.analytics.core.LemuConfig
import com.lemuai.analytics.core.Storage
import java.io.File

/**
 * Lemu analytics for Android.
 *
 * ```kotlin
 * class App : Application() {
 *     override fun onCreate() {
 *         super.onCreate()
 *         Lemu.setup(this, "lpk_...", LemuOptions(debug = BuildConfig.DEBUG))
 *     }
 * }
 *
 * Lemu.track(LemuEvent.ADD_TO_CART, mapOf("value" to 999, "currency" to "INR", "content_ids" to listOf("SKU1")))
 * Lemu.purchase(value = 1499.5, currency = "INR", orderId = "1042")
 * ```
 *
 * Every method is safe to call from any thread and never throws. Calls made before [setup] are
 * ignored with a Logcat warning.
 */
object Lemu {
    private const val TAG = "Lemu"

    // Intent.EXTRA_REFERRER_NAME (API 22); the literal works on every version.
    private const val EXTRA_REFERRER_NAME = "android.intent.extra.REFERRER_NAME"

    @Volatile private var client: LemuClient? = null
    private var warnedNotSetUp = false

    /** True once [setup] has run. */
    @JvmStatic
    val isSetUp: Boolean get() = client != null

    /**
     * Starts the SDK. Call once, from `Application.onCreate()` in the main process.
     * Later calls are ignored.
     */
    @JvmStatic
    @JvmOverloads
    fun setup(
        context: Context,
        writeKey: String,
        options: LemuOptions = LemuOptions(),
    ) {
        try {
            synchronized(this) {
                if (client != null) {
                    if (options.debug) Log.w(TAG, "setup() already called; ignored")
                    return
                }
                @Suppress("SENSELESS_COMPARISON")
                if (writeKey == null || writeKey.isBlank()) {
                    Log.w(TAG, "setup() needs your write key (Settings > Tracking sources in Lemu)")
                    return
                }
                val app = context.applicationContext ?: context
                val androidContext = AndroidContext(app)
                val config =
                    LemuConfig(
                        writeKey = writeKey.trim(),
                        apiHost = options.apiHost,
                        platform = "android",
                        libraryName = "lemu-android",
                        userAgent = androidContext.userAgent,
                        requireConsent = options.requireConsent,
                        debug = options.debug,
                        flushAt = options.flushAt.coerceIn(1, LemuConfig.MAX_BATCH_MESSAGES),
                        flushIntervalMillis = options.flushIntervalSeconds.coerceAtLeast(1) * 1000L,
                        maxQueueSize = options.maxQueueSize.coerceIn(1, 10_000),
                        trackLifecycleEvents = options.trackLifecycleEvents,
                        trackDeepLinks = options.trackDeepLinks,
                        collectInstallReferrer = options.collectInstallReferrer,
                    )
                val referrer =
                    if (options.collectInstallReferrer && PlayInstallReferrer.isAvailable()) PlayInstallReferrer(app) else null
                val c =
                    LemuClient(
                        config = config,
                        storage = storageFor(app, config.writeKey),
                        contextProvider = androidContext::current,
                        logger = AndroidLogger,
                        installReferrerSource = referrer,
                    )
                client = c
                if (options.debug) Log.d(TAG, "setup: ${androidContext.userAgent}, anonymousId ${c.anonymousId}")
                c.applicationLaunched(androidContext.appVersion, androidContext.appBuild)
                if (app is Application) {
                    app.registerActivityLifecycleCallbacks(DeepLinkCallbacks(options.trackDeepLinks))
                    if (options.trackActivityScreens) LemuActivityScreenTracker.register(app)
                }
                onMainThread { observeProcessLifecycle() }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "setup failed; Lemu is disabled", t)
        }
    }

    /** Sends a `track` message. Use [LemuEvent] constants for Meta standard events. */
    @JvmStatic
    @JvmOverloads
    fun track(
        event: String,
        properties: Map<String, Any?>? = null,
    ) = withClient { it.track(event, properties) }

    /** Sends a `screen` message, for example `screen("Checkout", mapOf("step" to 2))`. */
    @JvmStatic
    @JvmOverloads
    fun screen(
        name: String,
        properties: Map<String, Any?>? = null,
    ) = withClient { it.screen(name, properties) }

    /**
     * Ties this device to your own user id and records contact details (`email`, `phone` in E.164,
     * `first_name`, `last_name`, `name`, anything else). The user id is sent on every later message
     * until [reset].
     */
    @JvmStatic
    @JvmOverloads
    fun identify(
        userId: String? = null,
        traits: Map<String, Any?>? = null,
    ) = withClient { it.identify(userId, traits) }

    /**
     * Records an order and sends it at once. [orderId] lets Lemu count one conversion per order
     * when the app, website, Shopify or your server all report the same order.
     */
    @JvmStatic
    @JvmOverloads
    fun purchase(
        value: Double,
        currency: String,
        orderId: String,
        contents: List<LemuContent>? = null,
        contentIds: List<String>? = null,
        numItems: Int? = null,
        properties: Map<String, Any?>? = null,
    ) = withClient { it.purchase(value, currency, orderId, contents, contentIds, numItems, properties) }

    /** Call on logout: a new anonymous id, and the user id is cleared. */
    @JvmStatic
    fun reset() = withClient { it.reset() }

    /** Sends queued messages now. */
    @JvmStatic
    fun flush() = withClient { it.flush() }

    /** With `requireConsent`, call `setConsent(true)` once the user agrees and `setConsent(false)` if they withdraw. */
    @JvmStatic
    fun setConsent(granted: Boolean) = withClient { it.setConsent(granted) }

    /** Stops all tracking and clears queued messages. Remembered across launches. */
    @JvmStatic
    fun optOut() = withClient { it.optOut() }

    /** Undoes [optOut]. */
    @JvmStatic
    fun optIn() = withClient { it.optIn() }

    /** This install's anonymous id, or null before [setup]. */
    @JvmStatic
    val anonymousId: String?
        get() = client?.anonymousId

    /**
     * Records a link that opened the app (`deep_link_opened`) and copies its UTM parameters into
     * the campaign for later messages. Links that start an activity are captured automatically
     * when `trackDeepLinks` is on; call this from `onNewIntent` for links delivered to a running activity.
     */
    @JvmStatic
    @JvmOverloads
    fun trackDeepLink(
        intent: Intent?,
        referrer: String? = null,
    ) {
        try {
            val url = intent?.data?.toString() ?: return
            withClient { it.deepLinkOpened(url, referrer ?: referrerFrom(intent)) }
        } catch (_: Throwable) {
        }
    }

    // ------------------------------------------------------------------ internals

    private fun withClient(block: (LemuClient) -> Unit) {
        try {
            val c = client
            if (c == null) {
                if (!warnedNotSetUp) {
                    warnedNotSetUp = true
                    Log.w(TAG, "Lemu.setup() has not been called; call ignored")
                }
                return
            }
            block(c)
        } catch (_: Throwable) {
        }
    }

    private fun storageFor(
        context: Context,
        writeKey: String,
    ): Storage {
        return try {
            // noBackupFilesDir: the queue and ids are not restored onto another device by Auto Backup.
            val base = context.noBackupFilesDir
            val dirName = writeKey.replace(Regex("[^A-Za-z0-9_-]"), "_").take(64)
            FileStorage(File(File(base, "lemu"), dirName))
        } catch (t: Throwable) {
            Log.w(TAG, "storage unavailable; using memory", t)
            InMemoryStorage()
        }
    }

    private fun onMainThread(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            Handler(Looper.getMainLooper()).post { block() }
        }
    }

    @Volatile private var openedUrl: String? = null

    private fun observeProcessLifecycle() {
        try {
            var started = false
            ProcessLifecycleOwner.get().lifecycle.addObserver(
                LifecycleEventObserver { _, event ->
                    try {
                        val c = client ?: return@LifecycleEventObserver
                        when (event) {
                            Lifecycle.Event.ON_START -> {
                                val url = openedUrl
                                openedUrl = null
                                c.applicationOpened(fromBackground = started, url = url)
                                started = true
                            }
                            Lifecycle.Event.ON_STOP -> c.applicationBackgrounded()
                            else -> Unit
                        }
                    } catch (_: Throwable) {
                    }
                },
            )
        } catch (t: Throwable) {
            Log.w(TAG, "lifecycle tracking unavailable (is androidx.startup disabled?)", t)
        }
    }

    private fun referrerFrom(intent: Intent): String? =
        try {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_REFERRER))?.toString()
                ?: intent.getStringExtra(EXTRA_REFERRER_NAME)
        } catch (_: Throwable) {
            null
        }

    private fun activityReferrer(activity: Activity): String? =
        try {
            if (Build.VERSION.SDK_INT >= 22) activity.referrer?.toString() else referrerFrom(activity.intent)
        } catch (_: Throwable) {
            null
        }

    /** Captures links that start an activity, so `app_opened` can carry the `url`. */
    private class DeepLinkCallbacks(private val trackDeepLinks: Boolean) : Application.ActivityLifecycleCallbacks {
        override fun onActivityCreated(
            activity: Activity,
            savedInstanceState: Bundle?,
        ) {
            try {
                if (savedInstanceState != null) return
                val intent = activity.intent ?: return
                if (intent.action != Intent.ACTION_VIEW) return
                val url = intent.data?.toString() ?: return
                openedUrl = url
                if (trackDeepLinks) {
                    withClient { it.deepLinkOpened(url, activityReferrer(activity)) }
                }
            } catch (_: Throwable) {
            }
        }

        override fun onActivityStarted(activity: Activity) = Unit

        override fun onActivityResumed(activity: Activity) = Unit

        override fun onActivityPaused(activity: Activity) = Unit

        override fun onActivityStopped(activity: Activity) = Unit

        override fun onActivitySaveInstanceState(
            activity: Activity,
            outState: Bundle,
        ) = Unit

        override fun onActivityDestroyed(activity: Activity) = Unit
    }
}
