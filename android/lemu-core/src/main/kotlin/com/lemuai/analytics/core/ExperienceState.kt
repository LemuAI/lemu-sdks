package com.lemuai.analytics.core

import kotlin.random.Random

/** What the app remembers for one experience: times shown and closed, submit, sticky variant. */
class ExperienceSeen(
    var n: Long = 0,
    var last: Long = 0,
    var closes: Long = 0,
    var lastClose: Long = 0,
    var submitted: Long = 0,
    var variant: String? = null,
    var sessionShown: String? = null,
) {
    fun toMap(): Map<String, Any?> {
        val m = linkedMapOf<String, Any?>("n" to n, "last" to last, "closes" to closes, "lastClose" to lastClose, "submitted" to submitted)
        if (variant != null) m["variant"] = variant
        if (sessionShown != null) m["sessionShown"] = sessionShown
        return m
    }

    companion object {
        fun fromMap(m: Map<String, Any?>): ExperienceSeen =
            ExperienceSeen(
                n = m["n"].asLong() ?: 0,
                last = m["last"].asLong() ?: 0,
                closes = m["closes"].asLong() ?: 0,
                lastClose = m["lastClose"].asLong() ?: 0,
                submitted = m["submitted"].asLong() ?: 0,
                variant = m["variant"] as? String,
                sessionShown = m["sessionShown"] as? String,
            )
    }
}

/**
 * Visits, the current session and per-experience history, kept in [Storage] under [KEY] as JSON
 * (the same shape the website keeps in localStorage). Times are epoch milliseconds.
 */
class ExperienceState(
    var visits: Long = 0,
    var first: Long = 0,
    var last: Long = 0,
    var session: String = "",
    var sessionStart: Long = 0,
    var popupsThisSession: Long = 0,
    val seen: MutableMap<String, ExperienceSeen> = LinkedHashMap(),
) {
    fun seen(key: String): ExperienceSeen = seen.getOrPut(key) { ExperienceSeen() }

    /** Starts a new session when there is none or the app was idle for more than 30 minutes. */
    fun touch(
        now: Long,
        random: Random = Random.Default,
    ): Boolean {
        val fresh = session.isEmpty() || now - last > SESSION_GAP_MS
        if (fresh) {
            visits += 1
            session = newSessionId(random)
            sessionStart = now
            popupsThisSession = 0
        }
        if (first == 0L) first = now
        last = now
        return fresh
    }

    fun toJson(): String {
        val seenMap = LinkedHashMap<String, Any?>()
        for ((k, v) in seen) seenMap[k] = v.toMap()
        return Json.encode(
            linkedMapOf(
                "visits" to visits,
                "first" to first,
                "last" to last,
                "session" to session,
                "sessionStart" to sessionStart,
                "popupsThisSession" to popupsThisSession,
                "seen" to seenMap,
            ),
        )
    }

    companion object {
        const val KEY = "lemu.experiences"
        const val SESSION_GAP_MS = 30L * 60 * 1000

        fun fromJson(text: String?): ExperienceState {
            if (text.isNullOrBlank()) return ExperienceState()
            val m =
                try {
                    Json.parse(text).asMap()
                } catch (_: Exception) {
                    null
                } ?: return ExperienceState()
            val seen = LinkedHashMap<String, ExperienceSeen>()
            m["seen"].asMap()?.forEach { (k, v) -> v.asMap()?.let { seen[k] = ExperienceSeen.fromMap(it) } }
            return ExperienceState(
                visits = m["visits"].asLong() ?: 0,
                first = m["first"].asLong() ?: 0,
                last = m["last"].asLong() ?: 0,
                session = m["session"] as? String ?: "",
                sessionStart = m["sessionStart"].asLong() ?: 0,
                popupsThisSession = m["popupsThisSession"].asLong() ?: 0,
                seen = seen,
            )
        }

        private fun newSessionId(random: Random): String {
            val chars = "abcdefghijklmnopqrstuvwxyz0123456789"
            val sb = StringBuilder()
            repeat(8) { sb.append(chars[random.nextInt(chars.length)]) }
            return sb.toString()
        }
    }
}
