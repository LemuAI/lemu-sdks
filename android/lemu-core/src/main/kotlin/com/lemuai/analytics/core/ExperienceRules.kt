package com.lemuai.analytics.core

import java.util.Calendar
import java.util.TimeZone

/**
 * Which in-app messages may show, for whom and how often. A port of the website runtime's
 * rules (sdks/js/packages/onsite/src/rules.ts and util.ts) so web and apps agree, including the
 * sticky variant assignment the server uses for reporting.
 */
object ExperienceRules {
    private const val HOUR_MS = 3_600_000L
    private const val DAY_MS = 24 * HOUR_MS

    // ------------------------------------------------------------------ compare

    /** Same rules as the server's compare (api/services/onsite/decide.py) and util.ts. */
    @JvmStatic
    fun compare(
        actual: Any?,
        op: String?,
        expected: Any?,
    ): Boolean {
        val o = if (op.isNullOrEmpty()) "eq" else op
        when (o) {
            "exists" -> return actual != null && actual != "" && !(actual is List<*> && actual.isEmpty())
            "not_exists" -> return !compare(actual, "exists", expected)
            "in", "not_in" -> {
                val list: List<Any?> = if (expected is List<*>) expected else jsString(expected).split(",")
                val a = jsString(actual).trim().lowercase()
                val found = list.any { jsString(it).trim().lowercase() == a }
                return if (o == "in") found else !found
            }
            "contains", "not_contains" -> {
                val found = jsString(actual ?: "").lowercase().contains(jsString(expected).lowercase())
                return if (o == "contains") found else !found
            }
            "gt", "gte", "lt", "lte" -> {
                val a = jsNumber(actual)
                val b = jsNumber(expected)
                if (a.isNaN() || b.isNaN()) return false
                return when (o) {
                    "gt" -> a > b
                    "gte" -> a >= b
                    "lt" -> a < b
                    else -> a <= b
                }
            }
        }
        val equal =
            if (expected is Boolean || actual is Boolean) {
                truthy(actual) == truthy(expected)
            } else {
                jsString(actual).trim().lowercase() == jsString(expected).trim().lowercase()
            }
        return if (o == "neq") !equal else equal
    }

    private fun truthy(v: Any?): Boolean =
        when (v) {
            null -> false
            is String -> v.trim().lowercase() in setOf("true", "1", "yes", "y")
            is Boolean -> v
            is Number -> v.toDouble().let { it != 0.0 && !it.isNaN() }
            else -> true
        }

    private fun jsNumber(v: Any?): Double =
        when (v) {
            null -> Double.NaN
            is Boolean -> if (v) 1.0 else 0.0
            is Number -> v.toDouble()
            is String -> v.trim().let { if (it.isEmpty()) 0.0 else it.toDoubleOrNull() ?: Double.NaN }
            else -> Double.NaN
        }

    /** Event names match ignoring case, spaces, `_` and `-` (`add_to_cart` matches `AddToCart`). */
    @JvmStatic
    fun sameEvent(
        configured: String?,
        incoming: String?,
    ): Boolean {
        if (configured.isNullOrEmpty()) return false
        val norm = { s: String? -> (s ?: "").lowercase().replace(Regex("[\\s_-]+"), "") }
        return norm(configured) == norm(incoming)
    }

    // ------------------------------------------------------------------ variants

    /** FNV-1a over UTF-16 code units, as an unsigned 32-bit value. */
    @JvmStatic
    fun fnv1a(text: String): Long {
        var h = 0x811c9dc5L
        for (c in text) {
            h = h xor c.code.toLong()
            h = (h * 0x01000193L) and 0xffffffffL
        }
        return h
    }

    /** Stable 0..1 bucket for (visitor, experience). */
    @JvmStatic
    fun bucket(text: String): Double = fnv1a(text).toDouble() / 0xffffffffL.toDouble()

    /** Sticky variant key (or `holdout`) for [visitorId]; remembered in [seen]. */
    @JvmStatic
    fun assign(
        exp: Experience,
        visitorId: String,
        seen: ExperienceSeen,
    ): String {
        val previous = seen.variant
        if (previous != null && previous.isNotEmpty()) {
            val keep = if (previous == "holdout") exp.holdoutPct > 0 else exp.variants.any { it.key == previous }
            if (keep) return previous
        }
        val roll = bucket(visitorId + ":" + exp.id)
        val chosen: String
        if (roll * 100 < exp.holdoutPct) {
            chosen = "holdout"
        } else {
            val span = (100 - exp.holdoutPct).let { if (it == 0.0) 1.0 else it }
            val rest = (roll * 100 - exp.holdoutPct) / span
            val total = exp.variants.sumOf { maxOf(0.0, it.weight) }.let { if (it == 0.0) 1.0 else it }
            var acc = 0.0
            var pick = exp.variants.last().key
            for (v in exp.variants) {
                acc += maxOf(0.0, v.weight) / total
                if (rest < acc) {
                    pick = v.key
                    break
                }
            }
            chosen = pick
        }
        seen.variant = chosen
        return chosen
    }

    // ------------------------------------------------------------------ where, who, when, how often

    /** Screen rules: `any`, `screen_equals`, `screen_prefix` (both ignore case). Web-only rules never match. */
    @JvmStatic
    fun ruleMatches(
        rule: ExperienceRule,
        screen: String,
    ): Boolean {
        val s = screen.trim().lowercase()
        val v = rule.value.trim().lowercase()
        return when (rule.type) {
            "any" -> true
            "screen_equals" -> s == v
            "screen_prefix" -> s.startsWith(v)
            else -> false
        }
    }

    @JvmStatic
    fun whereMatches(
        exp: Experience,
        screen: String,
    ): Boolean {
        val include = if (exp.include.isEmpty()) listOf(ExperienceRule("any", "")) else exp.include
        if (include.none { ruleMatches(it, screen) }) return false
        return exp.exclude.none { ruleMatches(it, screen) }
    }

    /** The app conditions (`visitor`, `visit_count`, `identified`); others are left out. */
    private fun appCondition(
        c: Map<String, Any?>,
        userId: String?,
        state: ExperienceState,
    ): Boolean? {
        val op = c["op"] as? String
        return when (c["kind"]) {
            "visitor" -> compare(if (state.visits > 1) "returning" else "new", op, c["value"])
            "visit_count" -> compare(state.visits, op, c["value"])
            "identified" -> compare(userId != null, op, if (c.containsKey("value") && c["value"] != null) c["value"] else true)
            else -> null
        }
    }

    @JvmStatic
    fun whoMatches(
        exp: Experience,
        decision: ExperienceDecision?,
        userId: String?,
        state: ExperienceState,
    ): Boolean {
        val results = exp.who.conditions.mapNotNull { appCondition(it, userId, state) }
        val server = decision?.experiences?.get(exp.key)
        if (exp.who.server && server == null) return false
        if (server != null && server.hidden) return false
        val serverCount = exp.who.serverConditions
        if (exp.who.match == "any") {
            if (results.isEmpty() && serverCount == 0) return true
            return results.any { it } || (serverCount > 0 && server != null && server.match == true)
        }
        return results.all { it } && (serverCount == 0 || server == null || server.match != false)
    }

    /** Start / end dates, days of the week (0 = Monday) and hours in the schedule's time zone. */
    @JvmStatic
    fun scheduleOpen(
        schedule: Map<String, Any?>,
        now: Long,
    ): Boolean {
        val start = (schedule["start"] as? String)?.let { parseIso(it) }
        if (start != null && now < start) return false
        val end = (schedule["end"] as? String)?.let { parseIso(it) }
        if (end != null && now >= end) return false
        val tzName = schedule["timezone"] as? String ?: "Asia/Kolkata"
        var tz = TimeZone.getTimeZone(tzName)
        if (tz.id == "GMT" && tzName != "GMT") tz = TimeZone.getDefault()
        val cal = Calendar.getInstance(tz)
        cal.timeInMillis = now
        val day = (cal.get(Calendar.DAY_OF_WEEK) + 5) % 7
        val minutes = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        val days = (schedule["days_of_week"] as? List<*>)?.mapNotNull { it.asInt() } ?: emptyList()
        if (days.isNotEmpty() && day !in days) return false
        val hours = schedule["hours"].asMap()
        val fromText = hours?.get("from") as? String
        val toText = hours?.get("to") as? String
        if (!fromText.isNullOrEmpty() && !toText.isNullOrEmpty()) {
            val from = toMinutes(fromText)
            val to = toMinutes(toText)
            val closed = if (from <= to) minutes < from || minutes >= to else minutes < from && minutes >= to
            if (closed) return false
        }
        return true
    }

    private fun toMinutes(t: String): Int {
        val parts = t.split(":")
        val h = parts[0].trim().toIntOrNull() ?: 0
        val m = parts.getOrNull(1)?.trim()?.toIntOrNull() ?: 0
        return h * 60 + m
    }

    private val ISO =
        Regex("^(\\d{4})-(\\d{2})-(\\d{2})(?:[T ](\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.(\\d+))?)?)?\\s*(Z|[+-]\\d{2}:?\\d{2})?$")

    /** ISO 8601 date or date-time to epoch milliseconds (no zone means UTC); null when unreadable. */
    @JvmStatic
    fun parseIso(text: String): Long? {
        val m = ISO.matchEntire(text.trim()) ?: return null
        val g = m.groupValues
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.clear()
        cal.set(g[1].toInt(), g[2].toInt() - 1, g[3].toInt(), g[4].ifEmpty { "0" }.toInt(), g[5].ifEmpty { "0" }.toInt(), g[6].ifEmpty { "0" }.toInt())
        var millis = cal.timeInMillis
        if (g[7].isNotEmpty()) millis += (g[7] + "00").substring(0, 3).toLong()
        val zone = g[8]
        if (zone.isNotEmpty() && zone != "Z") {
            val sign = if (zone[0] == '-') -1 else 1
            val digits = zone.substring(1).replace(":", "")
            val offset = (digits.substring(0, 2).toInt() * 60 + digits.substring(2, 4).toInt()) * 60_000L
            millis -= sign * offset
        }
        return millis
    }

    /** How often: per session / day / N days / ever, stop after submit, stop after N closes, cooldown after a close. */
    @JvmStatic
    fun frequencyAllows(
        exp: Experience,
        seen: ExperienceSeen,
        state: ExperienceState,
        now: Long,
    ): Boolean {
        val f = exp.frequency
        if (f.stopAfterSubmit && seen.submitted != 0L) return false
        val maxCloses = f.maxCloses
        if (maxCloses != null && maxCloses != 0 && seen.closes >= maxCloses) return false
        val cooldown = ((f.cooldownHoursAfterClose ?: 24.0) * HOUR_MS).toLong()
        if (seen.lastClose != 0L && cooldown != 0L && now - seen.lastClose < cooldown) return false
        return when (f.show) {
            "always" -> true
            "session" -> seen.sessionShown != state.session
            "day" -> seen.last == 0L || now - seen.last > DAY_MS
            "days" -> {
                val days = f.days?.takeIf { it != 0.0 } ?: 7.0
                seen.last == 0L || now - seen.last > (days * DAY_MS).toLong()
            }
            "ever" -> seen.n == 0L
            else -> true
        }
    }
}
