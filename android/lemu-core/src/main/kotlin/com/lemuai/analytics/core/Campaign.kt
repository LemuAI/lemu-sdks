package com.lemuai.analytics.core

import java.net.URLDecoder

/**
 * Reads campaign parameters (`utm_*`, `gclid`, `fbclid`) from a deep link URL or from the
 * Play install referrer string (which is a bare query string such as `utm_source=google&utm_medium=cpc`).
 */
object Campaign {
    private val UTM_KEYS = listOf("source", "medium", "campaign", "term", "content", "id")
    private val CLICK_IDS = listOf("gclid", "fbclid", "lmclid")

    /** Campaign fields from a full URL (`https://brand.com/p?utm_source=x`, `brand://open?utm_source=x`). */
    @JvmStatic
    fun fromUrl(url: String?): Map<String, String> {
        if (url.isNullOrBlank()) return emptyMap()
        val q = url.indexOf('?')
        if (q < 0) return emptyMap()
        val end = url.indexOf('#', q).let { if (it < 0) url.length else it }
        return fromQuery(url.substring(q + 1, end))
    }

    /** Campaign fields from a query string (`utm_source=google&utm_medium=cpc`). */
    @JvmStatic
    fun fromQuery(query: String?): Map<String, String> {
        if (query.isNullOrBlank()) return emptyMap()
        val params = LinkedHashMap<String, String>()
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            val rawKey = if (eq < 0) pair else pair.substring(0, eq)
            val rawValue = if (eq < 0) "" else pair.substring(eq + 1)
            val key = decode(rawKey).lowercase()
            val value = decode(rawValue)
            if (value.isEmpty()) continue
            if (key.startsWith("utm_")) {
                val name = key.removePrefix("utm_")
                if (name in UTM_KEYS && name !in params) params[name] = value
            } else if (key in CLICK_IDS && key !in params) {
                params[key] = value
            }
        }
        return params
    }

    private fun decode(s: String): String =
        try {
            URLDecoder.decode(s, "UTF-8")
        } catch (_: Exception) {
            s
        }
}
