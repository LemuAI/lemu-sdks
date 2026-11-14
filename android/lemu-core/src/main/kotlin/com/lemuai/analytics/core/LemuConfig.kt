package com.lemuai.analytics.core

/** SDK version sent in `context.library.version` and the User-Agent. */
object LemuVersion {
    const val NAME: String = "1.0.0"
}

/**
 * Settings for [LemuClient]. The Android module builds this from `LemuOptions`.
 *
 * @property writeKey the source's public write key (`pk_...`).
 * @property apiHost collection host, `https://app.lemuai.com` by default.
 * @property userAgent sent on every request; requests without one are dropped as bots.
 */
class LemuConfig
    @JvmOverloads
    constructor(
        val writeKey: String,
        val apiHost: String = DEFAULT_API_HOST,
        val platform: String = "android",
        val libraryName: String = "lemu-android",
        val libraryVersion: String = LemuVersion.NAME,
        val userAgent: String = "lemu-jvm/${LemuVersion.NAME} (${System.getProperty("os.name") ?: "JVM"} ${System.getProperty("os.version") ?: ""}; unknown)",
        val requireConsent: Boolean = false,
        val debug: Boolean = false,
        val flushAt: Int = 20,
        val flushIntervalMillis: Long = 30_000L,
        val maxQueueSize: Int = 1_000,
        val trackLifecycleEvents: Boolean = true,
        val trackDeepLinks: Boolean = true,
        val collectInstallReferrer: Boolean = true,
    ) {
        val batchUrl: String get() = apiHost.trimEnd('/') + "/api/v1/pixel/batch"

        companion object {
            const val DEFAULT_API_HOST: String = "https://app.lemuai.com"

            /** Most messages per request (the server accepts 100; SDKs send at most 50). */
            const val MAX_BATCH_MESSAGES: Int = 50

            /** Request size budget, below the server's 256 KB limit. */
            const val MAX_BATCH_BYTES: Int = 240 * 1024

            /** Messages held in memory while waiting for consent. */
            const val MAX_HELD_BEFORE_CONSENT: Int = 50

            const val MAX_MESSAGE_AGE_MILLIS: Long = 7L * 24 * 60 * 60 * 1000

            /** Give up retrying a batch this long after its first attempt that may have reached the server. */
            const val RETRY_WINDOW_MILLIS: Long = 20L * 60 * 60 * 1000

            const val BACKOFF_BASE_MILLIS: Long = 1_000L
            const val BACKOFF_MAX_MILLIS: Long = 5L * 60 * 1000
            const val BACKOFF_JITTER: Double = 0.2

            /** How long `app_installed` waits for the Play install referrer before it is sent without it. */
            const val INSTALL_REFERRER_TIMEOUT_MILLIS: Long = 10_000L
        }
    }

/**
 * Supplies the raw Play install referrer string (`utm_source=...&utm_medium=...`) once.
 * The callback may run on any thread; pass null when unavailable.
 */
fun interface InstallReferrerSource {
    fun fetch(onResult: (String?) -> Unit)
}
