package com.lemuai.analytics

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Log
import com.lemuai.analytics.core.LemuLogger
import com.lemuai.analytics.core.LemuVersion
import java.util.Locale
import java.util.TimeZone

/** App and device facts for `context`. Read once at setup; locale and time zone are read per message. */
internal class AndroidContext(context: Context) {
    val appName: String
    val appVersion: String
    val appBuild: String
    val packageName: String = context.packageName
    val userAgent: String
    private val static: Map<String, Any?>

    init {
        val pm = context.packageManager
        val info: PackageInfo? =
            try {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(context.packageName, 0)
            } catch (_: PackageManager.NameNotFoundException) {
                null
            } catch (_: RuntimeException) {
                null
            }
        appName =
            try {
                context.applicationInfo.loadLabel(pm).toString()
            } catch (_: Exception) {
                packageName
            }
        appVersion = info?.versionName ?: ""
        appBuild =
            if (info == null) {
                ""
            } else if (Build.VERSION.SDK_INT >= 28) {
                info.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toString()
            }
        val model = Build.MODEL ?: "unknown"
        userAgent = "lemu-android/${LemuVersion.NAME} (Android ${Build.VERSION.RELEASE}; $model)"

        val metrics = context.resources.displayMetrics
        val app = LinkedHashMap<String, Any?>()
        app["name"] = appName
        if (appVersion.isNotEmpty()) app["version"] = appVersion
        if (appBuild.isNotEmpty()) app["build"] = appBuild
        app["namespace"] = packageName
        static =
            linkedMapOf(
                "app" to app,
                "device" to
                    linkedMapOf(
                        "manufacturer" to (Build.MANUFACTURER ?: "unknown"),
                        "model" to model,
                        "type" to deviceType(context),
                    ),
                "os" to linkedMapOf("name" to "Android", "version" to (Build.VERSION.RELEASE ?: "")),
                "screen" to
                    linkedMapOf(
                        "width" to metrics.widthPixels,
                        "height" to metrics.heightPixels,
                        "density" to metrics.density.toDouble(),
                    ),
                "userAgent" to userAgent,
            )
    }

    fun current(): Map<String, Any?> {
        val ctx = LinkedHashMap<String, Any?>(static)
        ctx["locale"] = Locale.getDefault().toLanguageTag()
        ctx["timezone"] = TimeZone.getDefault().id
        return ctx
    }

    companion object {
        /** `tv` for TV ui mode, `tablet` when the smallest width is at least 600dp, otherwise `phone`. */
        fun deviceType(context: Context): String {
            return try {
                val ui = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
                if (ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return "tv"
                deviceTypeForWidth(context.resources.configuration.smallestScreenWidthDp)
            } catch (_: Exception) {
                "phone"
            }
        }

        fun deviceTypeForWidth(smallestScreenWidthDp: Int): String = if (smallestScreenWidthDp >= 600) "tablet" else "phone"
    }
}

/** Logs to Logcat with the tag `Lemu`. */
internal object AndroidLogger : LemuLogger {
    private const val TAG = "Lemu"

    override fun debug(message: String) {
        try {
            Log.d(TAG, message)
        } catch (_: Throwable) {
        }
    }

    override fun warn(
        message: String,
        error: Throwable?,
    ) {
        try {
            if (error != null) Log.w(TAG, message, error) else Log.w(TAG, message)
        } catch (_: Throwable) {
        }
    }
}
