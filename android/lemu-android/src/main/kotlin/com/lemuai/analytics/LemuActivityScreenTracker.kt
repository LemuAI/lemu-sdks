package com.lemuai.analytics

import android.app.Activity
import android.app.Application
import android.content.pm.PackageManager
import android.os.Bundle

/**
 * Opt-in screen tracking: sends a `screen` message (stored by Lemu as `screen_viewed`) each time
 * an activity starts. Turn it on with `LemuOptions(trackActivityScreens = true)` or register it
 * yourself to choose the names:
 *
 * ```kotlin
 * LemuActivityScreenTracker.register(application) { activity -> activity.title?.toString() }
 * ```
 *
 * Return null from [nameFor] to skip an activity. Apps built on a single activity with Compose or
 * Fragments should call [Lemu.screen] from their navigation instead.
 */
class LemuActivityScreenTracker
    @JvmOverloads
    constructor(
        private val nameFor: ((Activity) -> String?)? = null,
    ) : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            try {
                val name = nameFor?.invoke(activity) ?: if (nameFor == null) defaultName(activity) else null
                if (!name.isNullOrBlank()) Lemu.screen(name)
            } catch (_: Throwable) {
            }
        }

        override fun onActivityCreated(
            activity: Activity,
            savedInstanceState: Bundle?,
        ) = Unit

        override fun onActivityResumed(activity: Activity) = Unit

        override fun onActivityPaused(activity: Activity) = Unit

        override fun onActivityStopped(activity: Activity) = Unit

        override fun onActivitySaveInstanceState(
            activity: Activity,
            outState: Bundle,
        ) = Unit

        override fun onActivityDestroyed(activity: Activity) = Unit

        companion object {
            /** Registers a tracker on [application] and returns it (keep it to unregister). */
            @JvmStatic
            @JvmOverloads
            fun register(
                application: Application,
                nameFor: ((Activity) -> String?)? = null,
            ): LemuActivityScreenTracker {
                val tracker = LemuActivityScreenTracker(nameFor)
                application.registerActivityLifecycleCallbacks(tracker)
                return tracker
            }

            /** The activity's own label when it has one, otherwise its class name. */
            internal fun defaultName(activity: Activity): String {
                try {
                    val info = activity.packageManager.getActivityInfo(activity.componentName, PackageManager.GET_META_DATA)
                    if (info.labelRes != 0 || info.nonLocalizedLabel != null) {
                        val label = info.loadLabel(activity.packageManager)?.toString()
                        if (!label.isNullOrBlank()) return label
                    }
                } catch (_: Throwable) {
                }
                return activity.javaClass.simpleName
            }
        }
    }
