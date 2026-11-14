package com.lemuai.analytics

import com.lemuai.analytics.core.LemuConfig

/**
 * Options for [Lemu.setup]. From Java, use [LemuOptions.builder].
 *
 * @property apiHost collection host. Change it only for testing or a first-party collection domain.
 * @property debug log every call, request and response to Logcat (tag `Lemu`).
 * @property requireConsent send and store nothing until [Lemu.setConsent] is called with true.
 * @property trackLifecycleEvents send `app_installed`, `app_updated`, `app_opened`, `app_backgrounded`.
 * @property trackDeepLinks send `deep_link_opened` for links that open an activity, and copy UTM parameters into the campaign.
 * @property collectInstallReferrer read the Play install referrer on first launch (needs the
 *   `com.android.installreferrer:installreferrer` dependency in the app; skipped when it is absent).
 * @property trackActivityScreens send a `screen` message each time an activity starts. Off by default.
 * @property flushAt send when this many messages are queued.
 * @property flushIntervalSeconds send at least this often while messages are queued.
 * @property maxQueueSize most messages kept on disk while offline.
 */
class LemuOptions
    @JvmOverloads
    constructor(
        val apiHost: String = LemuConfig.DEFAULT_API_HOST,
        val debug: Boolean = false,
        val requireConsent: Boolean = false,
        val trackLifecycleEvents: Boolean = true,
        val trackDeepLinks: Boolean = true,
        val collectInstallReferrer: Boolean = true,
        val trackActivityScreens: Boolean = false,
        val flushAt: Int = 20,
        val flushIntervalSeconds: Int = 30,
        val maxQueueSize: Int = 1_000,
    ) {
        /** Java-friendly builder: `LemuOptions.builder().debug(true).requireConsent(true).build()`. */
        class Builder {
            private var apiHost: String = LemuConfig.DEFAULT_API_HOST
            private var debug = false
            private var requireConsent = false
            private var trackLifecycleEvents = true
            private var trackDeepLinks = true
            private var collectInstallReferrer = true
            private var trackActivityScreens = false
            private var flushAt = 20
            private var flushIntervalSeconds = 30
            private var maxQueueSize = 1_000

            fun apiHost(value: String) = apply { apiHost = value }

            fun debug(value: Boolean) = apply { debug = value }

            fun requireConsent(value: Boolean) = apply { requireConsent = value }

            fun trackLifecycleEvents(value: Boolean) = apply { trackLifecycleEvents = value }

            fun trackDeepLinks(value: Boolean) = apply { trackDeepLinks = value }

            fun collectInstallReferrer(value: Boolean) = apply { collectInstallReferrer = value }

            fun trackActivityScreens(value: Boolean) = apply { trackActivityScreens = value }

            fun flushAt(value: Int) = apply { flushAt = value }

            fun flushIntervalSeconds(value: Int) = apply { flushIntervalSeconds = value }

            fun maxQueueSize(value: Int) = apply { maxQueueSize = value }

            fun build(): LemuOptions =
                LemuOptions(
                    apiHost = apiHost,
                    debug = debug,
                    requireConsent = requireConsent,
                    trackLifecycleEvents = trackLifecycleEvents,
                    trackDeepLinks = trackDeepLinks,
                    collectInstallReferrer = collectInstallReferrer,
                    trackActivityScreens = trackActivityScreens,
                    flushAt = flushAt,
                    flushIntervalSeconds = flushIntervalSeconds,
                    maxQueueSize = maxQueueSize,
                )
        }

        companion object {
            @JvmStatic
            fun builder(): Builder = Builder()
        }
    }
