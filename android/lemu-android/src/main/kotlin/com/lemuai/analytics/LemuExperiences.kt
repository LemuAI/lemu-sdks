package com.lemuai.analytics

import android.os.Handler
import android.os.Looper
import com.lemuai.analytics.core.ExperienceEngine

/**
 * In-app messages: the experiences you build in Lemu (popups, slide-ins, toasts and bars) shown
 * in your app with native views. Reach it through [Lemu.experiences].
 *
 * ```kotlin
 * Lemu.experiences.show("size_alert")           // show one now (manual trigger)
 * Lemu.experiences.setEnabled(false)            // pause automatic messages, for example during checkout
 * Lemu.experiences.setListener(object : LemuExperienceListener {
 *     override fun onSubmitted(event: LemuExperienceEvent) { /* event.fields, event.offerCode */ }
 * })
 * ```
 *
 * Messages follow the screens you report with [Lemu.screen] and the events you send with
 * [Lemu.track]. Every method is safe from any thread and does nothing before [Lemu.setup] or when
 * `LemuOptions(inAppMessages = false)`.
 */
class LemuExperiences internal constructor() {
    @Volatile private var engine: ExperienceEngine? = null

    @Volatile private var enabledFlag = true

    @Volatile private var listener: LemuExperienceListener? = null

    private val main: Handler by lazy { Handler(Looper.getMainLooper()) }

    /**
     * Shows the experience with this [key] now, whatever its screen, trigger, audience and
     * frequency rules say, and even while paused with [setEnabled]. Visitors in the experience's
     * holdout group still see nothing. Returns false when nothing could be shown: the key is
     * unknown, its format isn't supported in apps, another message is on screen, or the
     * experiences haven't loaded yet (it is then shown once they arrive).
     */
    fun show(key: String): Boolean =
        try {
            engine?.show(key) ?: false
        } catch (_: Throwable) {
            false
        }

    /** Closes the message on screen, if any. */
    fun hide() {
        try {
            engine?.hide()
        } catch (_: Throwable) {
        }
    }

    /** False pauses automatic messages (screen, delay and event triggers). [show] still works. */
    fun setEnabled(enabled: Boolean) {
        enabledFlag = enabled
        engine?.enabled = enabled
    }

    /** Whether automatic messages are on. */
    val isEnabled: Boolean get() = enabledFlag

    /** Fetches your live experiences now. They are also refreshed when the app returns to the foreground (at most every 5 minutes). */
    fun refresh() {
        try {
            engine?.refresh()
        } catch (_: Throwable) {
        }
    }

    /** Called on the main thread when a message is shown, closed, submitted or a link in it is tapped. Null removes it. */
    fun setListener(listener: LemuExperienceListener?) {
        this.listener = listener
    }

    // ------------------------------------------------------------------ wiring from Lemu

    internal fun attach(engine: ExperienceEngine) {
        engine.enabled = enabledFlag
        engine.listener = { event -> deliver(event) }
        this.engine = engine
    }

    internal fun postToMain(task: Runnable) {
        if (Looper.myLooper() == Looper.getMainLooper()) task.run() else main.post(task)
    }

    private fun deliver(event: LemuExperienceEvent) {
        val l = listener ?: return
        try {
            when (event.type) {
                LemuExperienceEvent.Type.SHOWN -> l.onShown(event)
                LemuExperienceEvent.Type.CLOSED -> l.onClosed(event)
                LemuExperienceEvent.Type.SUBMITTED -> l.onSubmitted(event)
                LemuExperienceEvent.Type.CLICKED -> l.onClicked(event)
            }
        } catch (_: Throwable) {
        }
    }

    internal fun onScreen(name: String?) {
        if (name.isNullOrBlank()) return
        try {
            engine?.onScreen(name)
        } catch (_: Throwable) {
        }
    }

    internal fun onTrack(
        event: String?,
        properties: Map<String, Any?>?,
    ) {
        if (event.isNullOrBlank()) return
        try {
            engine?.onTrack(event, properties)
        } catch (_: Throwable) {
        }
    }

    internal fun onForeground() {
        try {
            engine?.onForeground()
        } catch (_: Throwable) {
        }
    }

    internal fun onBackground() {
        try {
            engine?.onBackground()
        } catch (_: Throwable) {
        }
    }
}
