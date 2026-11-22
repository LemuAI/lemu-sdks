package com.lemuai.analytics.core

/*
 * In-app messages: the config bundle from `GET /api/v1/pixel/onsite/config` (built by the server's
 * onsite service), parsed from Json.parse maps. Only what apps use is kept.
 */

/** Formats apps render natively. Others in the bundle are ignored. */
internal val APP_FORMATS = setOf("popup", "slide_in", "toast", "bar")

/** Formats counted by `caps.popups_per_session` and `caps.popups_per_page`. */
internal val OVERLAY_FORMATS = setOf("popup", "slide_in")

class ExperienceRule(val type: String, val value: String)

class ExperienceTrigger(val on: String, val seconds: Double?, val event: String?)

class ExperienceFrequency(
    val show: String,
    val days: Double?,
    val stopAfterSubmit: Boolean,
    val maxCloses: Int?,
    val cooldownHoursAfterClose: Double?,
)

class ExperienceWho(
    val match: String,
    val conditions: List<Map<String, Any?>>,
    val server: Boolean,
    val serverConditions: Int,
)

class ExperienceVariant(val key: String, val weight: Double, val kind: String, val content: Map<String, Any?>)

class Experience(
    val id: Long,
    val key: String,
    val format: String,
    val platform: String,
    val priority: Long,
    val version: Long,
    val schedule: Map<String, Any?>,
    val include: List<ExperienceRule>,
    val exclude: List<ExperienceRule>,
    val who: ExperienceWho,
    val trigger: ExperienceTrigger,
    val frequency: ExperienceFrequency,
    val holdoutPct: Double,
    val variants: List<ExperienceVariant>,
)

class ExperienceBundle(
    val live: Boolean,
    val version: String?,
    val decide: Boolean,
    val theme: Map<String, Any?>,
    val popupsPerPage: Int?,
    val popupsPerSession: Int?,
    val experiences: List<Experience>,
) {
    fun find(key: String): Experience? = experiences.firstOrNull { it.key == key }

    companion object {
        @JvmField val EMPTY = ExperienceBundle(false, null, false, emptyMap(), null, null, emptyList())

        /**
         * Parses the bundle. `{"live": false}` and anything unreadable give [EMPTY]. Experiences for
         * the web, in formats apps don't render, or without variants are left out.
         */
        @JvmStatic
        fun parse(value: Any?): ExperienceBundle {
            val m = value.asMap() ?: return EMPTY
            if (m["live"] != true) return EMPTY
            val caps = m["caps"].asMap() ?: emptyMap()
            val list = (m["experiences"] as? List<*>)?.mapNotNull { parseExperience(it) } ?: emptyList()
            return ExperienceBundle(
                live = true,
                version = m["v"] as? String,
                decide = m["decide"] == true,
                theme = m["theme"].asMap() ?: emptyMap(),
                popupsPerPage = caps["popups_per_page"].asInt(),
                popupsPerSession = caps["popups_per_session"].asInt(),
                experiences = list,
            )
        }

        private fun parseExperience(value: Any?): Experience? {
            val e = value.asMap() ?: return null
            val key = e["key"] as? String ?: return null
            val format = e["format"] as? String ?: return null
            val platform = e["platform"] as? String ?: "any"
            if (platform != "app" && platform != "any") return null
            if (format !in APP_FORMATS) return null
            val variants =
                (e["variants"] as? List<*>)?.mapNotNull { v ->
                    val vm = v.asMap() ?: return@mapNotNull null
                    val vk = vm["key"] as? String ?: return@mapNotNull null
                    ExperienceVariant(vk, vm["weight"].asDouble() ?: 0.0, vm["kind"] as? String ?: "blocks", vm["content"].asMap() ?: emptyMap())
                } ?: emptyList()
            if (variants.isEmpty()) return null
            val where = e["where"].asMap() ?: emptyMap()
            val who = e["who"].asMap() ?: emptyMap()
            val trigger = e["trigger"].asMap() ?: emptyMap()
            val freq = e["frequency"].asMap()
            return Experience(
                id = e["id"].asLong() ?: 0L,
                key = key,
                format = format,
                platform = platform,
                priority = e["priority"].asLong() ?: 0L,
                version = e["version"].asLong() ?: 0L,
                schedule = e["schedule"].asMap() ?: emptyMap(),
                include = rules(where["include"]),
                exclude = rules(where["exclude"]),
                who =
                    ExperienceWho(
                        match = who["match"] as? String ?: "all",
                        conditions = (who["conditions"] as? List<*>)?.mapNotNull { it.asMap() } ?: emptyList(),
                        server = who["server"] == true,
                        serverConditions = who["server_conditions"].asInt() ?: 0,
                    ),
                trigger =
                    ExperienceTrigger(
                        on = trigger["on"] as? String ?: "page_load",
                        seconds = trigger["seconds"].asDouble(),
                        event = trigger["event"] as? String,
                    ),
                frequency =
                    if (freq == null) {
                        ExperienceFrequency("session", null, true, null, null)
                    } else {
                        ExperienceFrequency(
                            show = freq["show"] as? String ?: "",
                            days = freq["days"].asDouble(),
                            stopAfterSubmit = freq["stop_after_submit"] != false,
                            maxCloses = freq["max_closes"].asInt(),
                            cooldownHoursAfterClose = freq["cooldown_hours_after_close"].asDouble(),
                        )
                    },
                holdoutPct = e["holdout_pct"].asDouble() ?: 0.0,
                variants = variants,
            )
        }

        private fun rules(value: Any?): List<ExperienceRule> =
            (value as? List<*>)?.mapNotNull { r ->
                val rm = r.asMap() ?: return@mapNotNull null
                ExperienceRule(rm["type"] as? String ?: "", rm["value"]?.let { jsString(it) } ?: "")
            } ?: emptyList()
    }
}

/** The answer of `POST /api/v1/pixel/onsite/decide`. */
class ExperienceDecision(val known: Boolean, val experiences: Map<String, Answer>) {
    class Answer(val match: Boolean?, val hidden: Boolean)

    companion object {
        @JvmField val NONE = ExperienceDecision(false, emptyMap())

        @JvmStatic
        fun parse(value: Any?): ExperienceDecision? {
            val m = value.asMap() ?: return null
            val exps = m["experiences"].asMap() ?: return null
            val out = LinkedHashMap<String, Answer>()
            for ((k, v) in exps) {
                val a = v.asMap() ?: continue
                out[k] = Answer(a["match"] as? Boolean, a["hidden"] == true)
            }
            return ExperienceDecision(m["known"] == true, out)
        }
    }
}

// ------------------------------------------------------------------ helpers for parsed JSON

@Suppress("UNCHECKED_CAST")
internal fun Any?.asMap(): Map<String, Any?>? = this as? Map<String, Any?>

internal fun Any?.asDouble(): Double? =
    when (this) {
        is Number -> toDouble()
        is String -> trim().toDoubleOrNull()
        else -> null
    }

internal fun Any?.asLong(): Long? = asDouble()?.takeIf { !it.isNaN() && !it.isInfinite() }?.toLong()

internal fun Any?.asInt(): Int? = asLong()?.toInt()

/** JavaScript's `String(value)` for JSON values: 2.0 is "2", null is "null". */
internal fun jsString(value: Any?): String =
    when (value) {
        null -> "null"
        is Double -> if (!value.isNaN() && !value.isInfinite() && value == Math.floor(value) && Math.abs(value) < 1e15) value.toLong().toString() else value.toString()
        is Float -> jsString(value.toDouble())
        is List<*> -> value.joinToString(",") { if (it == null) "" else jsString(it) }
        else -> value.toString()
    }
