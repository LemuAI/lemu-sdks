package com.lemuai.analytics.core

import com.lemuai.analytics.LemuExperienceEvent
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.random.Random

/** A response: [status] is 0 when no response arrived. */
class ExperienceHttpReply(val status: Int, val body: String?)

/** GET and POST with the response body. Injected so tests need no network. */
interface ExperienceHttp {
    fun get(
        url: String,
        headers: Map<String, String>,
    ): ExperienceHttpReply

    fun post(
        url: String,
        body: String,
        headers: Map<String, String>,
    ): ExperienceHttpReply
}

/** [HttpURLConnection], so host apps get no OkHttp version clash. */
class UrlConnectionExperienceHttp(private val timeoutMillis: Int = 15_000) : ExperienceHttp {
    override fun get(
        url: String,
        headers: Map<String, String>,
    ): ExperienceHttpReply = request("GET", url, null, headers)

    override fun post(
        url: String,
        body: String,
        headers: Map<String, String>,
    ): ExperienceHttpReply = request("POST", url, body, headers)

    private fun request(
        method: String,
        url: String,
        body: String?,
        headers: Map<String, String>,
    ): ExperienceHttpReply {
        var conn: HttpURLConnection? = null
        return try {
            conn = URL(url).openConnection() as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = timeoutMillis
            conn.readTimeout = timeoutMillis
            conn.useCaches = false
            for ((k, v) in headers) conn.setRequestProperty(k, v)
            if (body != null) {
                val bytes = body.toByteArray(Charsets.UTF_8)
                conn.doOutput = true
                conn.setFixedLengthStreamingMode(bytes.size)
                conn.outputStream.use { it.write(bytes) }
            }
            val code = conn.responseCode
            val stream = if (code >= 400) conn.errorStream else conn.inputStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) }
            ExperienceHttpReply(code, text)
        } catch (_: Exception) {
            ExperienceHttpReply(0, null)
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
        }
    }
}

/** What the engine needs from the analytics client. */
interface ExperienceHost {
    val anonymousId: String?
    val userId: String?
    val isOptedOut: Boolean

    /** False while consent is pending: history then stays in memory. */
    val canPersist: Boolean

    fun track(
        event: String,
        properties: Map<String, Any?>,
    )
}

/** Puts in-app messages on screen. The Android module renders them with views. */
interface ExperiencePresenter {
    /** Shows [display] (called from any thread). Returns false when nothing can be shown now. */
    fun present(display: ExperienceDisplay): Boolean

    /** Removes [display] without calling back into the engine. */
    fun dismiss(display: ExperienceDisplay)
}

/** One in-app message on screen: what to render, and what the renderer reports back. */
class ExperienceDisplay internal constructor(
    private val engine: ExperienceEngine,
    val experience: Experience,
    val variant: ExperienceVariant,
    val theme: ExperienceTheme,
    /** The screen it was shown on. */
    val screen: String,
) {
    val format: String get() = experience.format
    val content: Map<String, Any?> get() = variant.content
    val layout: Map<String, Any?> = variant.content["layout"].asMap() ?: emptyMap()
    val steps: List<ExperienceStep> = ExperienceStep.of(variant.content)

    /** The user closed it ([byUser]) or it went away by itself (toast timer, after a submit). */
    fun close(byUser: Boolean) = engine.closed(this, byUser)

    /** A link was opened (`target` = URL) or the offer code copied (`copy_code`). */
    fun clicked(target: String) = engine.clicked(this, target)

    /** Posts the form. [done] runs on a background thread. */
    fun submit(
        fields: Map<String, Any?>,
        otp: String?,
        phoneCountry: String?,
        done: (ExperienceSubmitResult) -> Unit,
    ) = engine.submit(this, fields, otp, phoneCountry, done)
}

/**
 * In-app messages: fetches the source's experiences, follows screens and events, decides what
 * shows (rules, frequency, holdout, sticky variants) and reports views, closes and clicks
 * through the analytics client. Thread-safe; state is guarded by one lock.
 */
class ExperienceEngine
    @JvmOverloads
    constructor(
        private val writeKey: String,
        apiHost: String,
        private val userAgent: String?,
        private val platform: String,
        private val storage: Storage,
        private val host: ExperienceHost,
        private val presenter: ExperiencePresenter,
        private val http: ExperienceHttp = UrlConnectionExperienceHttp(),
        private val clock: Clock = Clock.SYSTEM,
        private val scheduler: TaskScheduler = BackgroundScheduler(),
        private val logger: LemuLogger? = null,
        private val dispatch: (Runnable) -> Unit = { it.run() },
        private val random: Random = Random.Default,
    ) {
        private val baseUrl = apiHost.trim().trimEnd('/')
        private val lock = Any()

        /** Receives shown, closed, submitted and clicked, through [dispatch]. */
        @Volatile var listener: ((LemuExperienceEvent) -> Unit)? = null

        /** False pauses automatic messages; `show(key)` still works. */
        @Volatile var enabled: Boolean = true

        private var state = ExperienceState()
        private var bundle: ExperienceBundle? = null
        private var lastFetch = 0L
        private var fetching = false
        private var started = false
        private var screen = ""
        private var sku: String? = null
        private var popupsThisScreen = 0
        private var showing: ExperienceDisplay? = null
        private var pendingShow: String? = null
        private val timers = ArrayList<Cancellable>()
        private val decisions = HashMap<String, Pair<Long, ExperienceDecision>>()
        private val decisionWaiters = HashMap<String, MutableList<() -> Unit>>()

        /** The message on screen, if any. */
        val current: ExperienceDisplay? get() = synchronized(lock) { showing }

        /** Loads history and fetches the config. Call once. */
        fun start() {
            guard("start") {
                synchronized(lock) {
                    if (started) return
                    started = true
                    if (host.canPersist) {
                        state = ExperienceState.fromJson(readState())
                    }
                    state.touch(clock.now(), random)
                    persist()
                }
                refresh()
            }
        }

        /** Fetches the config now. */
        fun refresh() {
            guard("refresh") {
                synchronized(lock) {
                    if (fetching || !started) return
                    fetching = true
                }
                scheduler.execute {
                    guard("config") {
                        val url = "$baseUrl/api/v1/pixel/onsite/config?k=" + URLEncoder.encode(writeKey, "UTF-8")
                        val reply = call { http.get(url, headers(false)) }
                        val parsed: ExperienceBundle? =
                            if (reply.status in 200..299 && reply.body != null) {
                                try {
                                    ExperienceBundle.parse(Json.parse(reply.body))
                                } catch (_: Exception) {
                                    null
                                }
                            } else {
                                null
                            }
                        synchronized(lock) {
                            fetching = false
                            if (parsed == null) {
                                logger?.debug("in-app messages: config not loaded (${reply.status})")
                                return@guard
                            }
                            val first = bundle == null
                            bundle = parsed
                            lastFetch = clock.now()
                            logger?.debug("in-app messages: ${parsed.experiences.size} experience(s)")
                            val key = pendingShow
                            pendingShow = null
                            if (key != null) showLocked(key)
                            if (first) armScreen()
                        }
                    }
                    synchronized(lock) { fetching = false }
                }
            }
        }

        /** The app came to the foreground: maybe a new session, and a fresh config every 5 minutes. */
        fun onForeground() {
            guard("foreground") {
                val stale =
                    synchronized(lock) {
                        if (!started) return
                        val now = clock.now()
                        state.touch(now, random)
                        persist()
                        now - lastFetch > REFRESH_MS
                    }
                if (stale) refresh()
            }
        }

        fun onBackground() {
            guard("background") {
                synchronized(lock) {
                    if (!started) return
                    state.last = clock.now()
                    persist()
                }
            }
        }

        /** A `screen(name)` call: where rules use it, page_load and delay triggers start again. */
        fun onScreen(name: String) {
            guard("screen") {
                synchronized(lock) {
                    screen = name.trim()
                    sku = null
                    popupsThisScreen = 0
                    cancelTimers()
                    if (bundle != null) armScreen()
                }
            }
        }

        /** A `track(event)` call: event triggers, and the product from `ViewContent`. */
        fun onTrack(
            event: String,
            properties: Map<String, Any?>?,
        ) {
            guard("track") {
                if (event.startsWith("onsite_")) return
                synchronized(lock) {
                    if (ExperienceRules.sameEvent("ViewContent", event)) sku = skuFrom(properties)
                    val b = bundle ?: return
                    for (exp in b.experiences) {
                        val name =
                            when (exp.trigger.on) {
                                "event" -> exp.trigger.event
                                "add_to_cart" -> "AddToCart"
                                else -> null
                            } ?: continue
                        if (ExperienceRules.sameEvent(name, event)) fire(exp.key)
                    }
                }
            }
        }

        /** Shows [key] now (manual trigger). Holdout still applies. */
        fun show(key: String): Boolean {
            return try {
                synchronized(lock) {
                    if (!started || host.isOptedOut) return false
                    if (bundle == null) {
                        pendingShow = key
                        return false
                    }
                    showLocked(key)
                }
            } catch (t: Throwable) {
                logger?.warn("in-app messages: show failed", t)
                false
            }
        }

        /** Closes the message on screen (not counted as a close by the user). */
        fun hide() {
            guard("hide") {
                val d =
                    synchronized(lock) {
                        val s = showing ?: return
                        showing = null
                        s
                    }
                try {
                    presenter.dismiss(d)
                } catch (_: Throwable) {
                }
                emit(LemuExperienceEvent(LemuExperienceEvent.Type.CLOSED, d.experience.key, d.variant.key, byUser = false))
            }
        }

        // ------------------------------------------------------------------ from the renderer

        internal fun closed(
            display: ExperienceDisplay,
            byUser: Boolean,
        ) {
            guard("close") {
                synchronized(lock) {
                    if (showing !== display) return
                    showing = null
                    if (byUser) {
                        val seen = state.seen(display.experience.key)
                        seen.closes += 1
                        seen.lastClose = clock.now()
                        persist()
                        host.track("onsite_closed", props(display.experience, display.variant.key, display.screen))
                    }
                }
                emit(LemuExperienceEvent(LemuExperienceEvent.Type.CLOSED, display.experience.key, display.variant.key, byUser = byUser))
            }
        }

        internal fun clicked(
            display: ExperienceDisplay,
            target: String,
        ) {
            guard("click") {
                val p = LinkedHashMap(props(display.experience, display.variant.key, display.screen))
                p["target"] = target
                host.track("onsite_clicked", p)
                emit(LemuExperienceEvent(LemuExperienceEvent.Type.CLICKED, display.experience.key, display.variant.key, target = target))
            }
        }

        internal fun submit(
            display: ExperienceDisplay,
            fields: Map<String, Any?>,
            otp: String?,
            phoneCountry: String?,
            done: (ExperienceSubmitResult) -> Unit,
        ) {
            val body = LinkedHashMap<String, Any?>()
            body["writeKey"] = writeKey
            body["experience"] = display.experience.key
            body["variant"] = display.variant.key
            body["anonymousId"] = host.anonymousId
            body["userId"] = host.userId
            body["fields"] = LinkedHashMap(fields)
            body["context"] = linkedMapOf("screen" to display.screen, "platform" to platform, "phone_country" to (phoneCountry ?: "+91"))
            if (!otp.isNullOrEmpty()) body["otp"] = otp
            val copy = LinkedHashMap(fields)
            scheduler.execute {
                var result = ExperienceSubmitResult(false, false, ExperienceText.ERROR_NETWORK, null)
                guard("submit") {
                    val reply = call { http.post("$baseUrl/api/v1/pixel/onsite/submit", Json.encode(body), headers(true)) }
                    result = ExperienceSubmitResult.from(reply.status, reply.body)
                    if (result.ok) {
                        synchronized(lock) {
                            state.seen(display.experience.key).submitted = clock.now()
                            persist()
                        }
                        emit(
                            LemuExperienceEvent(
                                LemuExperienceEvent.Type.SUBMITTED,
                                display.experience.key,
                                display.variant.key,
                                fields = copy,
                                offerCode = result.offer?.code,
                            ),
                        )
                    }
                }
                try {
                    done(result)
                } catch (_: Throwable) {
                }
            }
        }

        // ------------------------------------------------------------------ internals (hold the lock)

        private fun armScreen() {
            val b = bundle ?: return
            for (exp in b.experiences) {
                when (exp.trigger.on) {
                    "page_load" -> fire(exp.key)
                    "delay" -> {
                        val key = exp.key
                        val ms = ((exp.trigger.seconds ?: 0.0) * 1000).toLong().coerceAtLeast(0L)
                        timers.add(
                            scheduler.schedule(ms) {
                                guard("delay") { synchronized(lock) { fire(key) } }
                            },
                        )
                    }
                }
            }
        }

        private fun cancelTimers() {
            for (t in timers) {
                try {
                    t.cancel()
                } catch (_: Throwable) {
                }
            }
            timers.clear()
        }

        /** An automatic trigger fired for [key]: show it if every rule allows. */
        private fun fire(key: String) {
            val b = bundle ?: return
            val exp = b.find(key) ?: return
            if (!enabled || host.isOptedOut || showing != null) return
            val now = clock.now()
            if (!ExperienceRules.scheduleOpen(exp.schedule, now)) return
            if (!ExperienceRules.whereMatches(exp, screen)) return
            val seen = state.seen(exp.key)
            if (!ExperienceRules.frequencyAllows(exp, seen, state, now)) return
            if (!capsAllow(b, exp)) return
            var decision: ExperienceDecision? = null
            if (exp.who.server) {
                if (!b.decide) return
                decision = cachedDecision(now)
                if (decision == null) {
                    requestDecision { fire(key) }
                    return
                }
            }
            if (!ExperienceRules.whoMatches(exp, decision, host.userId, state)) return
            open(exp, b)
        }

        private fun showLocked(key: String): Boolean {
            val b = bundle ?: return false
            val exp = b.find(key) ?: return false
            if (showing != null || host.isOptedOut) return false
            return open(exp, b)
        }

        private fun capsAllow(
            b: ExperienceBundle,
            exp: Experience,
        ): Boolean {
            if (exp.format !in OVERLAY_FORMATS) return true
            val perPage = b.popupsPerPage
            if (perPage != null && popupsThisScreen >= perPage) return false
            val perSession = b.popupsPerSession
            if (perSession != null && state.popupsThisSession >= perSession) return false
            return true
        }

        private fun open(
            exp: Experience,
            b: ExperienceBundle,
        ): Boolean {
            val seen = state.seen(exp.key)
            val variantKey = ExperienceRules.assign(exp, visitorId(), seen)
            persist()
            if (variantKey == "holdout") {
                heldOut(exp, seen)
                return false
            }
            val variant = exp.variants.firstOrNull { it.key == variantKey } ?: return false
            if (variant.kind != "blocks") return false
            val theme = ExperienceTheme.from(b.theme, variant.content["style"].asMap() ?: emptyMap())
            val display = ExperienceDisplay(this, exp, variant, theme, screen)
            showing = display
            val ok =
                try {
                    presenter.present(display)
                } catch (t: Throwable) {
                    logger?.warn("in-app messages: could not show ${exp.key}", t)
                    false
                }
            if (!ok) {
                if (showing === display) showing = null
                return false
            }
            val now = clock.now()
            seen.n += 1
            seen.last = now
            seen.sessionShown = state.session
            if (exp.format in OVERLAY_FORMATS) {
                state.popupsThisSession += 1
                popupsThisScreen += 1
            }
            state.last = now
            persist()
            host.track("onsite_viewed", props(exp, variant.key, screen))
            emit(LemuExperienceEvent(LemuExperienceEvent.Type.SHOWN, exp.key, variant.key))
            return true
        }

        private fun heldOut(
            exp: Experience,
            seen: ExperienceSeen,
        ) {
            if (seen.sessionShown == state.session) return
            seen.sessionShown = state.session
            persist()
            host.track("onsite_held_out", props(exp, "holdout", screen))
        }

        private fun visitorId(): String = host.anonymousId?.takeIf { it.isNotEmpty() } ?: state.session

        private fun decisionKey(): String = screen + "|" + (sku ?: "")

        private fun cachedDecision(now: Long): ExperienceDecision? {
            val hit = decisions[decisionKey()] ?: return null
            return if (now - hit.first < DECIDE_TTL_MS) hit.second else null
        }

        private fun requestDecision(then: () -> Unit) {
            val k = decisionKey()
            val waiting = decisionWaiters[k]
            if (waiting != null) {
                waiting.add(then)
                return
            }
            decisionWaiters[k] = mutableListOf(then)
            val product: Map<String, Any?> = sku?.let { mapOf("sku" to it) } ?: emptyMap()
            val body =
                linkedMapOf(
                    "writeKey" to writeKey,
                    "anonymousId" to host.anonymousId,
                    "userId" to host.userId,
                    "context" to linkedMapOf("screen" to screen, "product" to product),
                )
            scheduler.execute {
                guard("decide") {
                    val reply = call { http.post("$baseUrl/api/v1/pixel/onsite/decide", Json.encode(body), headers(true)) }
                    val d =
                        if (reply.status in 200..299 && reply.body != null) {
                            try {
                                ExperienceDecision.parse(Json.parse(reply.body))
                            } catch (_: Exception) {
                                null
                            }
                        } else {
                            null
                        }
                    synchronized(lock) {
                        decisions[k] = Pair(clock.now(), d ?: ExperienceDecision.NONE)
                        val waiters = decisionWaiters.remove(k) ?: emptyList<() -> Unit>()
                        if (k == decisionKey()) for (w in waiters) w()
                    }
                }
            }
        }

        private fun props(
            exp: Experience,
            variant: String,
            onScreen: String,
        ): Map<String, Any?> =
            linkedMapOf(
                "experience_id" to exp.id,
                "experience" to exp.key,
                "variant" to variant,
                "version" to exp.version,
                "format" to exp.format,
                "screen" to onScreen,
            )

        private fun skuFrom(properties: Map<String, Any?>?): String? {
            if (properties == null) return null
            val ids = properties["content_ids"]
            val first = if (ids is List<*>) ids.firstOrNull() else null
            val v = first ?: properties["sku"] ?: properties["content_id"] ?: return null
            return jsString(v).takeIf { it.isNotBlank() }
        }

        private fun headers(json: Boolean): Map<String, String> {
            val h = LinkedHashMap<String, String>()
            h["Accept"] = "application/json"
            if (json) h["Content-Type"] = "application/json; charset=utf-8"
            if (!userAgent.isNullOrEmpty()) h["User-Agent"] = userAgent
            return h
        }

        private fun readState(): String? =
            try {
                storage.getString(ExperienceState.KEY)
            } catch (_: Throwable) {
                null
            }

        private fun persist() {
            if (!host.canPersist) return
            try {
                storage.putString(ExperienceState.KEY, state.toJson())
            } catch (t: Throwable) {
                logger?.warn("in-app messages: could not save history", t)
            }
        }

        private fun emit(event: LemuExperienceEvent) {
            val l = listener ?: return
            try {
                dispatch(
                    Runnable {
                        try {
                            l(event)
                        } catch (_: Throwable) {
                        }
                    },
                )
            } catch (_: Throwable) {
            }
        }

        private inline fun call(block: () -> ExperienceHttpReply): ExperienceHttpReply =
            try {
                block()
            } catch (_: Throwable) {
                ExperienceHttpReply(0, null)
            }

        private inline fun guard(
            what: String,
            block: () -> Unit,
        ) {
            try {
                block()
            } catch (t: Throwable) {
                try {
                    logger?.warn("in-app messages: $what failed", t)
                } catch (_: Throwable) {
                }
            }
        }

        companion object {
            const val REFRESH_MS: Long = 5L * 60 * 1000
            const val DECIDE_TTL_MS: Long = 10L * 60 * 1000
        }
    }
