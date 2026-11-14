package com.lemuai.analytics.sample

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.lemuai.analytics.Lemu
import com.lemuai.analytics.LemuContent
import com.lemuai.analytics.LemuEvent

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val status = TextView(this)
        val layout =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(48, 48, 48, 48)
            }
        fun button(
            label: String,
            action: () -> Unit,
        ) {
            layout.addView(
                Button(this).apply {
                    text = label
                    setOnClickListener {
                        action()
                        status.text = "$label sent. Anonymous id: ${Lemu.anonymousId}"
                    }
                },
            )
        }
        button("Add to cart") {
            Lemu.track(
                LemuEvent.ADD_TO_CART,
                mapOf("value" to 999, "currency" to "INR", "content_ids" to listOf("SKU1"), "content_type" to "product"),
            )
        }
        button("Purchase") {
            Lemu.purchase(
                value = 1499.5,
                currency = "INR",
                orderId = "sample-${System.currentTimeMillis()}",
                contents = listOf(LemuContent(id = "SKU1", quantity = 1, itemPrice = 1499.5)),
            )
        }
        button("Identify") { Lemu.identify("sample-user-1", mapOf("email" to "test@example.com", "first_name" to "Asha")) }
        button("Log out (reset)") { Lemu.reset() }
        button("Flush") { Lemu.flush() }
        button("Opt out") { Lemu.optOut() }
        button("Opt in") { Lemu.optIn() }
        layout.addView(status)
        setContentView(layout)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        Lemu.trackDeepLink(intent)
    }
}
