package com.lemuai.analytics.core

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * A small JSON encoder and parser. The SDK avoids org.json (a platform class on Android that
 * lint flags when bundled) and any third-party JSON library, so host apps get no version clashes.
 *
 * Values are plain Kotlin types: Map<String, Any?>, List<Any?>, String, Number, Boolean and null.
 */
object Json {
    fun encode(value: Any?): String {
        val sb = StringBuilder()
        write(sb, value, 0)
        return sb.toString()
    }

    /** Converts an arbitrary value into a JSON-safe value (maps, lists, strings, numbers, booleans, null). */
    fun sanitize(value: Any?, depth: Int = 0): Any? {
        if (depth > MAX_DEPTH) return null
        return when (value) {
            null -> null
            is String -> value
            is Boolean -> value
            is Double -> if (value.isNaN() || value.isInfinite()) null else value
            is Float -> if (value.isNaN() || value.isInfinite()) null else value.toDouble()
            is Number -> value
            is Char -> value.toString()
            is Date -> Iso8601.format(value.time)
            is Enum<*> -> value.name
            is Map<*, *> -> {
                val out = LinkedHashMap<String, Any?>()
                for ((k, v) in value) {
                    if (k == null) continue
                    out[k.toString()] = sanitize(v, depth + 1)
                }
                out
            }
            is Iterable<*> -> value.map { sanitize(it, depth + 1) }
            is Array<*> -> value.map { sanitize(it, depth + 1) }
            is IntArray -> value.toList()
            is LongArray -> value.toList()
            is DoubleArray -> value.map { sanitize(it, depth + 1) }
            is FloatArray -> value.map { sanitize(it, depth + 1) }
            is BooleanArray -> value.toList()
            is JsonConvertible -> sanitize(value.toJsonValue(), depth + 1)
            else -> value.toString()
        }
    }

    private fun write(sb: StringBuilder, value: Any?, depth: Int) {
        if (depth > MAX_DEPTH) {
            sb.append("null")
            return
        }
        when (value) {
            null -> sb.append("null")
            is String -> writeString(sb, value)
            is Boolean -> sb.append(if (value) "true" else "false")
            is Double -> writeDouble(sb, value)
            is Float -> writeDouble(sb, value.toDouble())
            is Number -> sb.append(value.toString())
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, v) in value) {
                    if (k == null) continue
                    if (!first) sb.append(',')
                    first = false
                    writeString(sb, k.toString())
                    sb.append(':')
                    write(sb, v, depth + 1)
                }
                sb.append('}')
            }
            is Iterable<*> -> {
                sb.append('[')
                var first = true
                for (v in value) {
                    if (!first) sb.append(',')
                    first = false
                    write(sb, v, depth + 1)
                }
                sb.append(']')
            }
            is RawJson -> sb.append(value.json)
            else -> write(sb, sanitize(value, depth), depth + 1)
        }
    }

    private fun writeDouble(sb: StringBuilder, d: Double) {
        if (d.isNaN() || d.isInfinite()) {
            sb.append("null")
        } else if (d == Math.rint(d) && Math.abs(d) < 1e15) {
            sb.append(d.toLong().toString())
        } else {
            sb.append(d.toString())
        }
    }

    private fun writeString(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (c < ' ' || c == ' ' || c == ' ') {
                    sb.append(String.format(Locale.US, "\\u%04x", c.code))
                } else {
                    sb.append(c)
                }
            }
        }
        sb.append('"')
    }

    /** Parses JSON text. Throws [IllegalArgumentException] on malformed input. */
    fun parse(text: String): Any? {
        val p = Parser(text)
        p.skipWs()
        val v = p.readValue(0)
        p.skipWs()
        require(p.pos == text.length) { "Trailing characters at ${p.pos}" }
        return v
    }

    private class Parser(val s: String) {
        var pos = 0

        fun skipWs() {
            while (pos < s.length && s[pos].isWhitespace()) pos++
        }

        fun readValue(depth: Int): Any? {
            require(depth <= MAX_DEPTH) { "Too deep" }
            require(pos < s.length) { "Unexpected end" }
            return when (val c = s[pos]) {
                '{' -> readObject(depth)
                '[' -> readArray(depth)
                '"' -> readString()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (c == '-' || c.isDigit()) readNumber() else throw IllegalArgumentException("Unexpected '$c' at $pos")
            }
        }

        private fun literal(word: String, v: Any?): Any? {
            require(s.startsWith(word, pos)) { "Bad literal at $pos" }
            pos += word.length
            return v
        }

        private fun readObject(depth: Int): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            pos++ // {
            skipWs()
            if (pos < s.length && s[pos] == '}') {
                pos++
                return out
            }
            while (true) {
                skipWs()
                require(pos < s.length && s[pos] == '"') { "Expected key at $pos" }
                val key = readString()
                skipWs()
                require(pos < s.length && s[pos] == ':') { "Expected ':' at $pos" }
                pos++
                skipWs()
                out[key] = readValue(depth + 1)
                skipWs()
                require(pos < s.length) { "Unexpected end" }
                when (s[pos]) {
                    ',' -> pos++
                    '}' -> {
                        pos++
                        return out
                    }
                    else -> throw IllegalArgumentException("Expected ',' or '}' at $pos")
                }
            }
        }

        private fun readArray(depth: Int): List<Any?> {
            val out = ArrayList<Any?>()
            pos++ // [
            skipWs()
            if (pos < s.length && s[pos] == ']') {
                pos++
                return out
            }
            while (true) {
                skipWs()
                out.add(readValue(depth + 1))
                skipWs()
                require(pos < s.length) { "Unexpected end" }
                when (s[pos]) {
                    ',' -> pos++
                    ']' -> {
                        pos++
                        return out
                    }
                    else -> throw IllegalArgumentException("Expected ',' or ']' at $pos")
                }
            }
        }

        private fun readString(): String {
            pos++ // opening quote
            val sb = StringBuilder()
            while (true) {
                require(pos < s.length) { "Unterminated string" }
                val c = s[pos++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        require(pos < s.length) { "Bad escape" }
                        when (val e = s[pos++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                require(pos + 4 <= s.length) { "Bad unicode escape" }
                                sb.append(s.substring(pos, pos + 4).toInt(16).toChar())
                                pos += 4
                            }
                            else -> throw IllegalArgumentException("Bad escape '\\$e'")
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }

        private fun readNumber(): Number {
            val start = pos
            if (s[pos] == '-') pos++
            while (pos < s.length && (s[pos].isDigit() || s[pos] in ".eE+-")) pos++
            val text = s.substring(start, pos)
            return if (text.any { it == '.' || it == 'e' || it == 'E' }) {
                text.toDouble()
            } else {
                text.toLongOrNull() ?: text.toDouble()
            }
        }
    }

    internal const val MAX_DEPTH = 32
}

/** Pre-encoded JSON inserted verbatim by [Json.encode]. */
class RawJson(val json: String)

/** Implemented by SDK value types (for example [com.lemuai.analytics.LemuContent]) to control their JSON form. */
interface JsonConvertible {
    fun toJsonValue(): Any?
}

/** ISO 8601 timestamps with milliseconds and a `Z` suffix, as the protocol requires. */
object Iso8601 {
    private val formatter = object : ThreadLocal<SimpleDateFormat>() {
        override fun initialValue(): SimpleDateFormat =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
    }

    fun format(epochMillis: Long): String = formatter.get()!!.format(Date(epochMillis))
}
