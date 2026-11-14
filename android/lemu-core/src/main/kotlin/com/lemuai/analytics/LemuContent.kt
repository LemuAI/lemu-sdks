package com.lemuai.analytics

import com.lemuai.analytics.core.JsonConvertible

/**
 * One line of an order or cart, sent in `contents` as Meta defines it:
 * `{id, quantity, item_price?, title?, brand?, category?}`.
 */
class LemuContent
    @JvmOverloads
    constructor(
        val id: String,
        val quantity: Int = 1,
        val itemPrice: Double? = null,
        val title: String? = null,
        val brand: String? = null,
        val category: String? = null,
    ) : JsonConvertible {
        override fun toJsonValue(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            m["id"] = id
            m["quantity"] = quantity
            itemPrice?.let { if (!it.isNaN() && !it.isInfinite()) m["item_price"] = it }
            title?.let { m["title"] = it }
            brand?.let { m["brand"] = it }
            category?.let { m["category"] = it }
            return m
        }

        override fun toString(): String = "LemuContent(id=$id, quantity=$quantity, itemPrice=$itemPrice)"
    }
