package com.lemuai.analytics.core

import com.lemuai.analytics.LemuContent
import com.lemuai.analytics.LemuEvent
import java.util.UUID
import kotlin.math.min
import kotlin.random.Random

/**
 * The platform-independent engine: builds messages, keeps the persistent queue and sends batches
 * as described in `spec/protocol.md`. The Android module wraps one instance in the `Lemu` singleton.
 *
 * Public methods never throw. They capture the call time and a message id on the caller's thread,
 * then do the rest on [scheduler], one task at a time.
 */
class LemuClient
    @JvmOverloads
    constructor(
        val config: LemuConfig,
        private val storage: Storage,
        private val contextProvider: () -> Map<String, Any?> = { emptyMap() },
        private val transport: HttpTransport = UrlConnectionTransport(),
        private val clock: Clock = Clock.SYSTEM,
        private val scheduler: TaskScheduler = BackgroundScheduler(),
        logger: LemuLogger = LemuLogger.STDOUT,
        private val installReferrerSource: InstallReferrerSource? = null,
        private val random: Random = Random.Default,
    ) {
        private val log: LemuLogger? = if (config.debug) logger else null

        @Volatile private var currentAnonymousId: String

        @Volatile private var currentUserId: String?

        @Volatile private var optedOut: Boolean

        @Volatile private var consentGranted: Boolean

        /** The id of this install, kept until [reset]. */
        val anonymousId: String get() = currentAnonymousId

        /** The user id set by [identify], or null. */
        val userId: String? get() = currentUserId

        val isOptedOut: Boolean get() = optedOut

        /** True when consent is not required or has been granted (in-app messages keep history on disk only then). */
        val hasConsent: Boolean get() = consentGranted

        // State below is only touched on the scheduler thread.
        private var identityPersisted = false
        private val held = ArrayDeque<HeldMessage>()
        private val queue = ArrayList<QueueItem>()
        private var campaign: Map<String, String> = emptyMap()
        private var pendingAppVersion: Pair<String, String>? = null
        private var retryCount = 0
        private var nextAttemptAt = 0L
        private var retryTask: Cancellable? = null
        private var flushTimer: Cancellable? = null
        private var closed = false

        init {
            optedOut = safeGet(KEY_OPT_OUT) == "true"
            consentGranted = !config.requireConsent || safeGet(KEY_CONSENT) == "true"
            val storedId = safeGet(KEY_ANONYMOUS_ID)?.takeIf { it.isNotBlank() && it.length <= 128 }
            currentAnonymousId = storedId ?: newId()
            identityPersisted = storedId != null
            currentUserId = if (storedId != null) safeGet(KEY_USER_ID) else null
            if (config.writeKey.isBlank()) log?.warn("Empty write key: nothing will be accepted by the server")
            scheduler.execute {
                guard("load") {
                    loadQueue()
                    if (storageAllowed()) persistIdentity()
                    scheduleFlushTimer()
                }
            }
        }

        // ---------------------------------------------------------------- public API

        /** Sends a `track` message. [event] is any name; use [LemuEvent] for Meta standard events. */
        fun track(
            event: String?,
            properties: Map<String, Any?>? = null,
        ) {
            guard("track") {
                if (event.isNullOrBlank()) {
                    log?.warn("track() ignored: empty event name")
                    return@guard
                }
                if (event == LemuEvent.PURCHASE) warnPurchaseFields(properties)
                log?.debug("track($event) $properties")
                enqueue("track", mapOf("event" to event, "properties" to cleanProperties(properties)))
            }
        }

        /** Sends a `screen` message (stored by Lemu as `screen_viewed`). */
        fun screen(
            name: String?,
            properties: Map<String, Any?>? = null,
        ) {
            guard("screen") {
                if (name.isNullOrBlank()) {
                    log?.warn("screen() ignored: empty name")
                    return@guard
                }
                log?.debug("screen($name) $properties")
                enqueue("screen", mapOf("name" to name, "properties" to cleanProperties(properties)))
            }
        }

        /**
         * Sends an `identify` message. A non-null [userId] is kept and sent on every later message
         * until [reset]. Contact details (`email`, `phone` in E.164, names) belong in [traits].
         */
        fun identify(
            userId: String? = null,
            traits: Map<String, Any?>? = null,
        ) {
            guard("identify") {
                val id = userId?.trim()?.takeIf { it.isNotEmpty() }
                if (id != null && id.length > 255) {
                    log?.warn("identify() ignored: userId longer than 255 characters")
                    return@guard
                }
                if (id == null && traits.isNullOrEmpty()) {
                    log?.warn("identify() ignored: no userId and no traits")
                    return@guard
                }
                log?.debug("identify($id) ${traits?.keys}")
                val ts = clock.now()
                val messageId = newId()
                val cleanTraits = cleanProperties(traits)
                scheduler.execute {
                    guard("identify") {
                        if (id != null && !optedOut) {
                            currentUserId = id
                            if (storageAllowed()) storage.putString(KEY_USER_ID, id)
                        }
                        enqueueNow("identify", mapOf("traits" to cleanTraits), ts, messageId)
                    }
                }
            }
        }

        /**
         * Sends `track` with `event: "Purchase"` and flushes at once. [orderId] lets Lemu count one
         * conversion per order however many sources (app, website, Shopify, server) report it.
         */
        fun purchase(
            value: Double,
            currency: String,
            orderId: String,
            contents: List<LemuContent>? = null,
            contentIds: List<String>? = null,
            numItems: Int? = null,
            properties: Map<String, Any?>? = null,
        ) {
            guard("purchase") {
                val props = LinkedHashMap<String, Any?>()
                cleanProperties(properties).let { props.putAll(it) }
                if (value.isNaN() || value.isInfinite()) {
                    log?.warn("purchase(): value is not a finite number; sent without value")
                } else {
                    props["value"] = value
                }
                @Suppress("SENSELESS_COMPARISON")
                if (currency == null || currency.isBlank()) {
                    log?.warn("purchase(): currency is empty; Lemu will use the workspace currency")
                } else {
                    props["currency"] = currency.trim().uppercase()
                }
                @Suppress("SENSELESS_COMPARISON")
                if (orderId == null || orderId.isBlank()) {
                    log?.warn("purchase(): order_id is empty; this order may be counted twice")
                } else {
                    props["order_id"] = orderId
                }
                if (!contents.isNullOrEmpty()) props["contents"] = Json.sanitize(contents)
                if (!contentIds.isNullOrEmpty()) props["content_ids"] = contentIds.filterNotNull()
                if (numItems != null) props["num_items"] = numItems
                log?.debug("purchase($value $currency, order $orderId)")
                enqueue("track", mapOf("event" to LemuEvent.PURCHASE, "properties" to props))
            }
        }

        /** Logout: a new anonymous id, user id cleared. */
        fun reset() {
            guard("reset") {
                log?.debug("reset()")
                scheduler.execute {
                    guard("reset") {
                        currentAnonymousId = newId()
                        currentUserId = null
                        identityPersisted = false
                        if (storageAllowed()) persistIdentity()
                    }
                }
            }
        }

        /** Sends queued messages now (still respecting a retry backoff in progress). */
        fun flush() {
            guard("flush") {
                log?.debug("flush()")
                scheduler.execute { guard("flush") { flushNow() } }
            }
        }

        /**
         * With `requireConsent`, nothing is sent or stored until `setConsent(true)`. Up to 50 messages
         * are held in memory meanwhile and sent on consent; `setConsent(false)` discards them.
         * Granted consent is remembered; call `setConsent(false)` when the user withdraws it.
         */
        fun setConsent(granted: Boolean) {
            guard("setConsent") {
                log?.debug("setConsent($granted)")
                scheduler.execute {
                    guard("setConsent") {
                        if (granted) {
                            consentGranted = true
                            if (optedOut) return@guard
                            storage.putString(KEY_CONSENT, "true")
                            persistIdentity()
                            pendingAppVersion?.let { (v, b) -> saveAppVersion(v, b) }
                            pendingAppVersion = null
                            val toSend = ArrayList(held)
                            held.clear()
                            for (h in toSend) addToQueue(h.message, h.queuedAt, h.purchase)
                            enforceQueueCap()
                            flushNow()
                        } else {
                            consentGranted = false
                            held.clear()
                            clearQueue()
                            safeRemove(KEY_CONSENT)
                        }
                    }
                }
            }
        }

        /** Stops all tracking and clears the queue. Remembered across launches until [optIn]. */
        fun optOut() {
            guard("optOut") {
                log?.debug("optOut()")
                optedOut = true
                scheduler.execute {
                    guard("optOut") {
                        held.clear()
                        clearQueue()
                        retryTask?.cancel()
                        retryTask = null
                        storage.putString(KEY_OPT_OUT, "true")
                    }
                }
            }
        }

        /** Undoes [optOut]. */
        fun optIn() {
            guard("optIn") {
                log?.debug("optIn()")
                optedOut = false
                scheduler.execute {
                    guard("optIn") {
                        safeRemove(KEY_OPT_OUT)
                        if (storageAllowed()) persistIdentity()
                    }
                }
            }
        }

        /** Sets the campaign (UTM parameters without `utm_`, `gclid`, `fbclid`) for later messages. */
        fun setCampaign(values: Map<String, String>?) {
            guard("setCampaign") {
                val copy = values?.filterValues { it.isNotEmpty() } ?: emptyMap()
                scheduler.execute { campaign = copy }
            }
        }

        // ---------------------------------------------------------------- app lifecycle

        /**
         * Call once per process start with the app's version name and build number. Sends
         * `app_installed` on the first launch (after the install referrer is read, when available)
         * or `app_updated` when the stored version differs.
         */
        fun applicationLaunched(
            version: String,
            build: String,
        ) {
            guard("applicationLaunched") {
                val ts = clock.now()
                val messageId = newId()
                scheduler.execute {
                    guard("applicationLaunched") {
                        if (optedOut) return@guard
                        val previousVersion = storage.getString(KEY_APP_VERSION)
                        val previousBuild = storage.getString(KEY_APP_BUILD)
                        saveAppVersion(version, build)
                        if (!config.trackLifecycleEvents) return@guard
                        if (previousVersion == null && previousBuild == null) {
                            trackInstall(version, build, ts, messageId)
                        } else if (previousVersion != version || previousBuild != build) {
                            val props = LinkedHashMap<String, Any?>()
                            props["version"] = version
                            props["build"] = build
                            props["previous_version"] = previousVersion
                            props["previous_build"] = previousBuild
                            enqueueNow("track", trackFields(LemuEvent.APP_UPDATED, props), ts, messageId)
                        }
                    }
                }
            }
        }

        /** `app_opened` on every foreground. [url] is the link that opened the app, if any. */
        fun applicationOpened(
            fromBackground: Boolean,
            url: String? = null,
        ) {
            guard("applicationOpened") {
                if (!config.trackLifecycleEvents) return@guard
                val props = LinkedHashMap<String, Any?>()
                props["from_background"] = fromBackground
                if (!url.isNullOrBlank()) props["url"] = url
                enqueue("track", trackFields(LemuEvent.APP_OPENED, props))
            }
        }

        /** `app_backgrounded`, then a flush. */
        fun applicationBackgrounded() {
            guard("applicationBackgrounded") {
                if (config.trackLifecycleEvents) {
                    enqueue("track", trackFields(LemuEvent.APP_BACKGROUNDED, emptyMap()))
                }
                scheduler.execute { guard("flush") { flushNow() } }
            }
        }

        /**
         * `deep_link_opened` with `url` and `referrer`. UTM parameters in the URL become
         * `context.campaign` for this and later messages of the session.
         */
        fun deepLinkOpened(
            url: String?,
            referrer: String? = null,
        ) {
            guard("deepLinkOpened") {
                if (url.isNullOrBlank()) return@guard
                val found = Campaign.fromUrl(url)
                val props = LinkedHashMap<String, Any?>()
                props["url"] = url
                if (!referrer.isNullOrBlank()) props["referrer"] = referrer
                val ts = clock.now()
                val messageId = newId()
                scheduler.execute {
                    guard("deepLinkOpened") {
                        if (found.isNotEmpty()) campaign = found
                        if (config.trackDeepLinks) {
                            enqueueNow("track", trackFields(LemuEvent.DEEP_LINK_OPENED, props), ts, messageId)
                        }
                    }
                }
            }
        }

        /** Stops timers. Queued messages stay on disk for the next instance. */
        fun close() {
            scheduler.execute {
                closed = true
                flushTimer?.cancel()
                retryTask?.cancel()
            }
        }

        // ---------------------------------------------------------------- test hooks

        internal fun queuedMessages(): List<String> = queue.map { it.json }

        internal fun heldCount(): Int = held.size

        // ---------------------------------------------------------------- internals

        private class HeldMessage(val message: Map<String, Any?>, val queuedAt: Long, val purchase: Boolean)

        private class QueueItem(
            val json: String,
            val queuedAt: Long,
            val purchase: Boolean,
            var firstAttemptAt: Long?,
        ) {
            val bytes: Int by lazy { json.toByteArray(Charsets.UTF_8).size }

            fun encode(): String = "$queuedAt\t${if (purchase) 1 else 0}\t${firstAttemptAt ?: ""}\t$json"

            companion object {
                fun decode(line: String): QueueItem? {
                    val parts = line.split('\t', limit = 4)
                    if (parts.size != 4 || !parts[3].startsWith("{")) return null
                    val queuedAt = parts[0].toLongOrNull() ?: return null
                    return QueueItem(parts[3], queuedAt, parts[1] == "1", parts[2].toLongOrNull())
                }
            }
        }

        private fun trackFields(
            event: String,
            props: Map<String, Any?>,
        ): Map<String, Any?> = mapOf("event" to event, "properties" to props)

        private fun trackInstall(
            version: String,
            build: String,
            ts: Long,
            messageId: String,
        ) {
            val props = linkedMapOf<String, Any?>("version" to version, "build" to build)
            val source = installReferrerSource
            if (source == null || !config.collectInstallReferrer) {
                enqueueNow("track", trackFields(LemuEvent.APP_INSTALLED, props), ts, messageId)
                return
            }
            var done = false
            val finish = { referrer: String? ->
                scheduler.execute {
                    guard("installReferrer") {
                        if (done) return@guard
                        done = true
                        val found = Campaign.fromQuery(referrer)
                        if (found.isNotEmpty()) {
                            campaign = found
                            log?.debug("install referrer campaign: $found")
                        }
                        enqueueNow("track", trackFields(LemuEvent.APP_INSTALLED, props), ts, messageId)
                    }
                }
            }
            scheduler.schedule(LemuConfig.INSTALL_REFERRER_TIMEOUT_MILLIS) { finish(null) }
            try {
                source.fetch { finish(it) }
            } catch (t: Throwable) {
                log?.warn("install referrer failed", t)
                finish(null)
            }
        }

        /** Captures time and id on the caller's thread, builds the message on the worker. */
        private fun enqueue(
            type: String,
            fields: Map<String, Any?>,
        ) {
            val ts = clock.now()
            val messageId = newId()
            scheduler.execute { guard(type) { enqueueNow(type, fields, ts, messageId) } }
        }

        private fun enqueueNow(
            type: String,
            fields: Map<String, Any?>,
            ts: Long,
            messageId: String,
        ) {
            if (optedOut) {
                log?.debug("opted out: $type dropped")
                return
            }
            val message = buildMessage(type, fields, ts, messageId)
            val purchase = type == "track" && fields["event"] == LemuEvent.PURCHASE
            if (!consentGranted) {
                held.addLast(HeldMessage(message, ts, purchase))
                while (held.size > LemuConfig.MAX_HELD_BEFORE_CONSENT) held.removeFirst()
                log?.debug("waiting for consent: $type held in memory (${held.size})")
                return
            }
            if (!identityPersisted) persistIdentity()
            addToQueue(message, ts, purchase)
            enforceQueueCap()
            if (purchase || queue.size >= config.flushAt) flushNow()
        }

        private fun buildMessage(
            type: String,
            fields: Map<String, Any?>,
            ts: Long,
            messageId: String,
        ): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            m["type"] = type
            m["messageId"] = messageId
            m["anonymousId"] = currentAnonymousId
            currentUserId?.let { m["userId"] = it }
            m["timestamp"] = Iso8601.format(ts)
            m.putAll(fields)
            m["context"] = buildContext()
            return m
        }

        private fun buildContext(): Map<String, Any?> {
            val ctx = LinkedHashMap<String, Any?>()
            try {
                for ((k, v) in contextProvider()) if (v != null) ctx[k] = v
            } catch (t: Throwable) {
                log?.warn("context provider failed", t)
            }
            ctx["platform"] = config.platform
            ctx["library"] = mapOf("name" to config.libraryName, "version" to config.libraryVersion)
            if (!ctx.containsKey("userAgent")) ctx["userAgent"] = config.userAgent
            if (campaign.isNotEmpty()) ctx["campaign"] = LinkedHashMap(campaign)
            // Never send advertising ids, whatever a custom provider returns.
            ctx.remove("advertisingId")
            ctx.remove("idfa")
            ctx.remove("gaid")
            return ctx
        }

        private fun addToQueue(
            message: Map<String, Any?>,
            queuedAt: Long,
            purchase: Boolean,
        ) {
            val item = QueueItem(Json.encode(message), queuedAt, purchase, null)
            queue.add(item)
            try {
                storage.appendQueue(item.encode())
            } catch (t: Throwable) {
                log?.warn("could not persist message; kept in memory", t)
            }
        }

        /** At most [LemuConfig.maxQueueSize] messages; drops the oldest non-Purchase first. */
        private fun enforceQueueCap() {
            val max = config.maxQueueSize.coerceAtLeast(1)
            if (queue.size <= max) return
            while (queue.size > max) {
                val idx = queue.indexOfFirst { !it.purchase }.let { if (it < 0) 0 else it }
                queue.removeAt(idx)
            }
            log?.debug("queue full: dropped oldest messages, ${queue.size} kept")
            persistQueue()
        }

        private fun loadQueue() {
            if (optedOut) return
            val lines =
                try {
                    storage.readQueue()
                } catch (t: Throwable) {
                    log?.warn("could not read queue", t)
                    emptyList()
                }
            var bad = 0
            for (line in lines) {
                val item = QueueItem.decode(line)
                if (item == null) bad++ else queue.add(item)
            }
            val before = queue.size
            dropExpired()
            if (bad > 0 && before == queue.size) persistQueue()
            if (queue.isNotEmpty()) log?.debug("loaded ${queue.size} queued messages")
        }

        private fun dropExpired() {
            val cutoff = clock.now() - LemuConfig.MAX_MESSAGE_AGE_MILLIS
            if (queue.removeAll { it.queuedAt < cutoff }) {
                log?.debug("dropped messages older than 7 days")
                persistQueue()
            }
        }

        private fun persistQueue() {
            try {
                storage.writeQueue(queue.map { it.encode() })
            } catch (t: Throwable) {
                log?.warn("could not persist queue", t)
            }
        }

        private fun clearQueue() {
            queue.clear()
            try {
                storage.writeQueue(emptyList())
            } catch (t: Throwable) {
                log?.warn("could not clear queue", t)
            }
        }

        private fun storageAllowed(): Boolean = !optedOut && consentGranted

        private fun persistIdentity() {
            try {
                storage.putString(KEY_ANONYMOUS_ID, currentAnonymousId)
                val uid = currentUserId
                if (uid != null) storage.putString(KEY_USER_ID, uid) else storage.remove(KEY_USER_ID)
                identityPersisted = true
            } catch (t: Throwable) {
                log?.warn("could not persist identity", t)
            }
        }

        private fun saveAppVersion(
            version: String,
            build: String,
        ) {
            if (!storageAllowed()) {
                pendingAppVersion = version to build
                return
            }
            try {
                storage.putString(KEY_APP_VERSION, version)
                storage.putString(KEY_APP_BUILD, build)
            } catch (t: Throwable) {
                log?.warn("could not persist app version", t)
            }
        }

        private fun scheduleFlushTimer() {
            if (closed || config.flushIntervalMillis <= 0) return
            flushTimer =
                scheduler.schedule(config.flushIntervalMillis) {
                    guard("timer") {
                        flushNow()
                        scheduleFlushTimer()
                    }
                }
        }

        // ---------------------------------------------------------------- sending

        private fun flushNow() {
            if (optedOut || !consentGranted || queue.isEmpty()) return
            dropExpired()
            val now = clock.now()
            if (now < nextAttemptAt) {
                log?.debug("flush deferred: retrying in ${nextAttemptAt - now} ms")
                return
            }
            while (queue.isNotEmpty() && !optedOut) {
                val batch = ArrayList<QueueItem>()
                var bytes = 0
                for (item in queue) {
                    if (batch.size >= LemuConfig.MAX_BATCH_MESSAGES) break
                    if (batch.isNotEmpty() && bytes + item.bytes > LemuConfig.MAX_BATCH_BYTES) break
                    batch.add(item)
                    bytes += item.bytes + 1
                }
                if (!deliver(batch)) return
            }
        }

        /** Sends [items]; returns false when sending should stop (a retry is scheduled). */
        private fun deliver(items: List<QueueItem>): Boolean {
            val sentAt = Iso8601.format(clock.now())
            val body =
                Json.encode(
                    linkedMapOf(
                        "writeKey" to config.writeKey,
                        "sentAt" to sentAt,
                        "batch" to items.map { RawJson(it.json) },
                    ),
                )
            log?.debug("POST ${config.batchUrl} (${items.size} messages) $body".take(4000))
            val headers =
                mapOf(
                    "Content-Type" to "application/json; charset=utf-8",
                    "User-Agent" to config.userAgent,
                    "Accept" to "*/*",
                )
            val result =
                try {
                    transport.post(config.batchUrl, body.toByteArray(Charsets.UTF_8), headers)
                } catch (t: Throwable) {
                    HttpResult.Failure(t, mayHaveReachedServer = true)
                }
            log?.debug("response: $result")
            return when (result) {
                is HttpResult.Response -> {
                    val code = result.code
                    when {
                        code in 200..299 -> {
                            removeFromQueue(items)
                            retryCount = 0
                            nextAttemptAt = 0
                            true
                        }
                        code == 413 -> {
                            if (items.size == 1) {
                                log?.warn("message too large for the server; dropped")
                                removeFromQueue(items)
                                true
                            } else {
                                val half = items.size / 2
                                deliver(items.subList(0, half)) && deliver(items.subList(half, items.size))
                            }
                        }
                        code == 429 || code >= 500 || code < 200 || code in 300..399 -> {
                            scheduleRetry(items, reached = true)
                            false
                        }
                        else -> {
                            // 400 malformed, 401 unknown or paused key, 403 not allowed, other 4xx.
                            log?.warn("server answered $code; batch of ${items.size} dropped")
                            removeFromQueue(items)
                            true
                        }
                    }
                }
                is HttpResult.Failure -> {
                    log?.warn("request failed", result.error)
                    scheduleRetry(items, reached = result.mayHaveReachedServer)
                    false
                }
            }
        }

        private fun removeFromQueue(items: List<QueueItem>) {
            val set = items.toHashSet()
            queue.removeAll { it in set }
            persistQueue()
        }

        private fun scheduleRetry(
            items: List<QueueItem>,
            reached: Boolean,
        ) {
            val now = clock.now()
            if (reached) {
                var changed = false
                for (item in items) {
                    if (item.firstAttemptAt == null) {
                        item.firstAttemptAt = now
                        changed = true
                    }
                }
                val expired = items.filter { a -> a.firstAttemptAt?.let { now - it >= LemuConfig.RETRY_WINDOW_MILLIS } == true }
                if (expired.isNotEmpty()) {
                    log?.warn("giving up on ${expired.size} messages after 20 hours of retries")
                    removeFromQueue(expired)
                } else if (changed) {
                    persistQueue()
                }
            }
            val delay = backoffDelay(retryCount)
            retryCount++
            nextAttemptAt = now + delay
            log?.debug("retry in $delay ms (attempt $retryCount)")
            retryTask?.cancel()
            retryTask = scheduler.schedule(delay) { guard("retry") { flushNow() } }
        }

        internal fun backoffDelay(attempt: Int): Long {
            val base = min(LemuConfig.BACKOFF_MAX_MILLIS, LemuConfig.BACKOFF_BASE_MILLIS shl min(attempt, 20))
            val jitter = 1.0 + (random.nextDouble() * 2 - 1) * LemuConfig.BACKOFF_JITTER
            return (base * jitter).toLong().coerceAtLeast(1)
        }

        // ---------------------------------------------------------------- helpers

        private fun cleanProperties(props: Map<String, Any?>?): Map<String, Any?> {
            if (props == null) return emptyMap()
            @Suppress("UNCHECKED_CAST")
            return (Json.sanitize(props) as? Map<String, Any?>) ?: emptyMap()
        }

        private fun warnPurchaseFields(props: Map<String, Any?>?) {
            val missing = LemuEvent.CONVERSION_REQUIRED_FIELDS.filter { props?.get(it) == null }
            if (missing.isNotEmpty()) {
                log?.warn("Purchase without ${missing.joinToString()}: use purchase() so ROI is counted correctly")
            }
        }

        private fun safeGet(key: String): String? =
            try {
                storage.getString(key)
            } catch (t: Throwable) {
                log?.warn("could not read $key", t)
                null
            }

        private fun safeRemove(key: String) {
            try {
                storage.remove(key)
            } catch (t: Throwable) {
                log?.warn("could not remove $key", t)
            }
        }

        private inline fun guard(
            what: String,
            block: () -> Unit,
        ) {
            try {
                block()
            } catch (t: Throwable) {
                try {
                    log?.warn("$what failed", t)
                } catch (_: Throwable) {
                }
            }
        }

        companion object {
            internal const val KEY_ANONYMOUS_ID = "anonymousId"
            internal const val KEY_USER_ID = "userId"
            internal const val KEY_OPT_OUT = "optOut"
            internal const val KEY_CONSENT = "consent"
            internal const val KEY_APP_VERSION = "appVersion"
            internal const val KEY_APP_BUILD = "appBuild"

            private fun newId(): String = UUID.randomUUID().toString()
        }
    }
