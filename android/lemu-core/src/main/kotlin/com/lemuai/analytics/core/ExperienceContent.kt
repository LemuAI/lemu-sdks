package com.lemuai.analytics.core

/*
 * In-app message content helpers shared by the Android renderer and the tests: theme colours,
 * text clean-up, fields, validation and the submit answer.
 */

/** Colours as ARGB ints, sizes in dp. */
class ExperienceTheme(
    val primary: Int,
    val text: Int,
    val background: Int,
    val muted: Int,
    val buttonText: Int,
    val overlay: Int,
    val radius: Float,
    val buttonRadius: Float,
    val outlineButtons: Boolean,
) {
    companion object {
        @JvmField val DEFAULT_PRIMARY = 0xFF111827.toInt()
        @JvmField val DEFAULT_TEXT = 0xFF111827.toInt()
        @JvmField val DEFAULT_BACKGROUND = 0xFFFFFFFF.toInt()
        @JvmField val DEFAULT_MUTED = 0xFF6B7280.toInt()
        @JvmField val DEFAULT_BUTTON_TEXT = 0xFFFFFFFF.toInt()
        @JvmField val DEFAULT_OVERLAY = 0x8C111827.toInt() // rgba(17,24,39,0.55)

        /** The bundle's theme with the variant's `content.style` on top. */
        @JvmStatic
        fun from(
            theme: Map<String, Any?>,
            style: Map<String, Any?>,
        ): ExperienceTheme {
            fun pick(
                styleKey: String,
                themeKey: String,
                fallback: Int,
            ): Int {
                val s = style[styleKey] as? String
                val t = theme[themeKey] as? String
                return parseColor(s?.takeIf { it.isNotBlank() }) ?: parseColor(t) ?: fallback
            }
            val radius = (style["radius"] ?: theme["radius"]).asDouble() ?: 12.0
            val pill = theme["button_style"] == "pill"
            return ExperienceTheme(
                primary = pick("primary_color", "primary_color", DEFAULT_PRIMARY),
                text = pick("text_color", "text_color", DEFAULT_TEXT),
                background = pick("background", "background_color", DEFAULT_BACKGROUND),
                muted = pick("muted_color", "muted_color", DEFAULT_MUTED),
                buttonText = pick("button_text_color", "button_text_color", DEFAULT_BUTTON_TEXT),
                overlay = pick("overlay_color", "overlay_color", DEFAULT_OVERLAY),
                radius = radius.toFloat(),
                buttonRadius = if (pill) 999f else (theme["button_radius"].asDouble() ?: 8.0).toFloat(),
                outlineButtons = theme["button_style"] == "outline",
            )
        }

        private val RGB = Regex("^rgba?\\(\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*(?:,\\s*([\\d.]+%?)\\s*)?\\)$")

        /** `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()` and `rgba()` to ARGB; null for anything else. */
        @JvmStatic
        fun parseColor(value: String?): Int? {
            val v = value?.trim()?.lowercase() ?: return null
            if (v.startsWith("#")) {
                val hex = v.substring(1)
                if (hex.any { it !in "0123456789abcdef" }) return null
                return when (hex.length) {
                    3 -> {
                        val r = hex[0].toString().repeat(2).toInt(16)
                        val g = hex[1].toString().repeat(2).toInt(16)
                        val b = hex[2].toString().repeat(2).toInt(16)
                        argb(255, r, g, b)
                    }
                    6 -> (0xFF000000L or hex.toLong(16)).toInt()
                    8 -> {
                        val rgb = hex.substring(0, 6).toLong(16)
                        val a = hex.substring(6, 8).toInt(16)
                        ((a.toLong() shl 24) or rgb).toInt()
                    }
                    else -> null
                }
            }
            val m = RGB.matchEntire(v) ?: return null
            val r = m.groupValues[1].toDoubleOrNull() ?: return null
            val g = m.groupValues[2].toDoubleOrNull() ?: return null
            val b = m.groupValues[3].toDoubleOrNull() ?: return null
            val aText = m.groupValues[4]
            val a =
                when {
                    aText.isEmpty() -> 1.0
                    aText.endsWith("%") -> (aText.dropLast(1).toDoubleOrNull() ?: 100.0) / 100.0
                    else -> aText.toDoubleOrNull() ?: 1.0
                }
            return argb((a.coerceIn(0.0, 1.0) * 255 + 0.5).toInt(), r.toInt(), g.toInt(), b.toInt())
        }

        private fun argb(
            a: Int,
            r: Int,
            g: Int,
            b: Int,
        ): Int = (a.coerceIn(0, 255) shl 24) or (r.coerceIn(0, 255) shl 16) or (g.coerceIn(0, 255) shl 8) or b.coerceIn(0, 255)
    }
}

/** One step of a variant: an id and its blocks. */
class ExperienceStep(val id: String, val blocks: List<Map<String, Any?>>) {
    val hasFields: Boolean get() = blocks.any { it["type"] == "field" }

    companion object {
        @JvmStatic
        fun of(content: Map<String, Any?>): List<ExperienceStep> =
            (content["steps"] as? List<*>)?.mapIndexedNotNull { i, s ->
                val m = s.asMap() ?: return@mapIndexedNotNull null
                ExperienceStep(m["id"] as? String ?: "step$i", (m["blocks"] as? List<*>)?.mapNotNull { it.asMap() } ?: emptyList())
            } ?: emptyList()
    }
}

class ExperienceOption(val value: String, val label: String)

/** A `field` block. */
class ExperienceField(
    val name: String,
    val input: String,
    val label: String,
    val placeholder: String,
    val required: Boolean,
    val options: List<ExperienceOption>,
    val defaultCountry: String,
    val checked: Boolean,
    val value: Any?,
) {
    val isCheckbox: Boolean get() = input == "consent" || input == "checkbox"
    val isChoice: Boolean get() = input in setOf("select", "size", "chips", "rating", "nps")
    val isHidden: Boolean get() = input == "hidden"

    companion object {
        @JvmStatic
        fun of(block: Map<String, Any?>): ExperienceField? {
            val name = block["name"] as? String ?: return null
            if (name.isEmpty()) return null
            val input = block["input"] as? String ?: "text"
            val options =
                when (input) {
                    "rating" -> (1..5).map { ExperienceOption(it.toString(), it.toString()) }
                    "nps" -> (0..10).map { ExperienceOption(it.toString(), it.toString()) }
                    else ->
                        (block["options"] as? List<*>)?.mapNotNull { o ->
                            when (o) {
                                null -> null
                                is Map<*, *> -> {
                                    val om = o.asMap() ?: emptyMap()
                                    val v = jsString(om["value"])
                                    val l = om["label"]?.let { jsString(it) }?.takeIf { it.isNotEmpty() } ?: v
                                    ExperienceOption(v, l)
                                }
                                else -> ExperienceOption(jsString(o), jsString(o))
                            }
                        } ?: emptyList()
                }
            return ExperienceField(
                name = name,
                input = input,
                label = ExperienceText.plain(block["label"] as? String ?: ""),
                placeholder = block["placeholder"] as? String ?: "",
                required = block["required"] == true,
                options = options,
                defaultCountry = (block["default_country"] as? String)?.takeIf { it.isNotBlank() } ?: "+91",
                checked = block["checked"] == true,
                value = block["value"],
            )
        }
    }
}

object ExperienceText {
    private val LINK = Regex("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
    private val BOLD = Regex("\\*\\*(.+?)\\*\\*")
    private val ITALIC = Regex("(^|[^*])\\*([^*]+)\\*(?!\\*)")
    private val PLACEHOLDER = Regex("\\{\\{\\s*([a-z_]+)\\.([a-z_0-9]+)\\s*\\}\\}", RegexOption.IGNORE_CASE)
    private val EMAIL = Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]{2,}$")

    const val ERROR_REQUIRED = "Please fill in the highlighted fields."
    const val ERROR_EMAIL = "Enter a valid email address."
    const val ERROR_PHONE = "Enter a valid phone number."
    const val ERROR_RATE_LIMIT = "Please try again in a minute."
    const val ERROR_GENERIC = "Something went wrong. Please try again."
    const val ERROR_NETWORK = "Couldn't send. Check your connection and try again."
    const val OTP_LABEL = "Enter the code we sent on WhatsApp"

    /** Plain text: `[label](url)` becomes the label, `**` and `*` markers are dropped. */
    @JvmStatic
    fun plain(text: String): String {
        var out = LINK.replace(text) { it.groupValues[1] }
        out = BOLD.replace(out) { it.groupValues[1] }
        out = ITALIC.replace(out) { it.groupValues[1] + it.groupValues[2] }
        return out.replace("**", "")
    }

    /** `{{answers.size}}`, `{{offer.code}}`. Unknown placeholders become empty. */
    @JvmStatic
    fun fill(
        template: String,
        scopes: Map<String, Map<String, Any?>>,
    ): String =
        PLACEHOLDER.replace(template) { m ->
            val v = scopes[m.groupValues[1]]?.get(m.groupValues[2])
            if (v == null) "" else jsString(v)
        }

    /** The first problem with a step's values, or null. Checkboxes hold Boolean, others String. */
    @JvmStatic
    fun validate(
        fields: List<ExperienceField>,
        values: Map<String, Any?>,
    ): String? {
        for (f in fields) {
            if (!f.required || f.isHidden) continue
            val v = values[f.name]
            val empty = if (f.isCheckbox) v != true else (v as? String).isNullOrBlank()
            if (empty) return ERROR_REQUIRED
        }
        for (f in fields) {
            val v = (values[f.name] as? String)?.trim() ?: continue
            if (v.isEmpty()) continue
            if (f.input == "email" && !EMAIL.matches(v)) return ERROR_EMAIL
            if (f.input == "phone" && v.count { it.isDigit() } < 6) return ERROR_PHONE
        }
        return null
    }

    /** What is sent for a phone field: the country code and digits, or the number as typed when it starts with `+`. */
    @JvmStatic
    fun phoneValue(
        raw: String,
        countryCode: String,
    ): String {
        val t = raw.trim()
        if (t.isEmpty()) return ""
        val digits = t.filter { it.isDigit() }
        if (t.startsWith("+")) return "+$digits"
        return countryCode + digits.trimStart('0')
    }

    /** After a successful submit: the first later step called `success` or without fields; -1 to close. */
    @JvmStatic
    fun stepAfterSubmit(
        steps: List<ExperienceStep>,
        current: Int,
    ): Int {
        for (i in current + 1 until steps.size) {
            if (steps[i].id == "success" || !steps[i].hasFields) return i
        }
        return -1
    }
}

/** The offer returned by a submit. */
class ExperienceOffer(val code: String?, val headline: String?, val terms: String?) {
    fun toMap(): Map<String, Any?> = mapOf("code" to code, "headline" to headline, "terms" to terms)
}

/** The answer of `POST /api/v1/pixel/onsite/submit`, ready for the renderer. */
class ExperienceSubmitResult(
    val ok: Boolean,
    val verify: Boolean,
    /** For a failure, or the OTP error when [verify] is true. */
    val error: String?,
    val offer: ExperienceOffer?,
) {
    companion object {
        @JvmStatic
        fun from(
            status: Int,
            body: String?,
        ): ExperienceSubmitResult {
            if (status <= 0) return ExperienceSubmitResult(false, false, ExperienceText.ERROR_NETWORK, null)
            val data =
                try {
                    if (body.isNullOrBlank()) null else Json.parse(body).asMap()
                } catch (_: Exception) {
                    null
                } ?: emptyMap()
            val errors = data["errors"].asMap() ?: emptyMap()
            if (data["verify"] == true) {
                return ExperienceSubmitResult(false, true, errors["_otp"]?.let { jsString(it) }, null)
            }
            if (data["ok"] != true) {
                val first = errors["_form"] ?: errors.values.firstOrNull { it != null }
                val message =
                    first?.let { jsString(it) }?.takeIf { it.isNotBlank() }
                        ?: if (status == 429) ExperienceText.ERROR_RATE_LIMIT else ExperienceText.ERROR_GENERIC
                return ExperienceSubmitResult(false, false, message, null)
            }
            val o = data["offer"].asMap()
            val offer =
                if (o == null) {
                    null
                } else {
                    ExperienceOffer(o["code"] as? String, o["headline"] as? String, o["terms"] as? String)
                }
            return ExperienceSubmitResult(true, false, null, offer)
        }
    }
}
