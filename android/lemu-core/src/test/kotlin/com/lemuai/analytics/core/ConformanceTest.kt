package com.lemuai.analytics.core

import com.lemuai.analytics.LemuContent
import com.lemuai.analytics.LemuEvent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Scenarios C01-C20 from conformance/README.md. Every recorded body is checked against batch.schema.json. */
@Suppress("UNCHECKED_CAST")
class ConformanceTest {
    @get:Rule val tmp = TemporaryFolder()

    private val h = Harness()

    @After fun tearDown() {
        h.assertAllValid()
        h.close()
    }

    private fun props(m: Map<String, Any?>) = m["properties"] as Map<String, Any?>

    private fun context(m: Map<String, Any?>) = m["context"] as Map<String, Any?>

    @Test fun C01_track_then_flush_sends_one_valid_request() {
        val lemu = h.client()
        lemu.track("AddToCart", mapOf("value" to 999, "currency" to "INR"))
        lemu.flush()

        assertEquals(1, h.server.requests.size)
        val req = h.server.requests[0]
        assertTrue(req.header("User-Agent")!!.startsWith("lemu-"))
        assertTrue(req.header("Content-Type")!!.startsWith("application/json"))
        assertEquals("pk_test_123", req.json["writeKey"])
        val m = req.batch.single()
        assertEquals("track", m["type"])
        assertEquals("AddToCart", m["event"])
        assertEquals(mapOf("value" to 999L, "currency" to "INR"), props(m))
        val ctx = context(m)
        assertEquals("android", ctx["platform"])
        assertEquals(mapOf("name" to "lemu-android", "version" to LemuVersion.NAME), ctx["library"])
        assertEquals("com.brand.app", (ctx["app"] as Map<String, Any?>)["namespace"])
    }

    @Test fun C02_same_anonymous_id_new_message_ids() {
        val lemu = h.client()
        lemu.track("A")
        lemu.track("B")
        lemu.flush()

        val batch = h.server.requests.single().batch
        assertEquals(2, batch.size)
        assertEquals(batch[0]["anonymousId"], batch[1]["anonymousId"])
        assertNotEquals(batch[0]["messageId"], batch[1]["messageId"])
        for (m in batch) {
            assertTrue(UUID_V4.matches(m["messageId"] as String))
            assertTrue(UUID_V4.matches(m["anonymousId"] as String))
        }
        assertEquals(lemu.anonymousId, batch[0]["anonymousId"])
    }

    @Test fun C03_identify_then_track_carries_user_id() {
        val lemu = h.client()
        lemu.identify("u1", mapOf("email" to "a@b.co"))
        lemu.track("X")
        lemu.flush()

        val (identify, track) = h.server.requests.single().batch
        assertEquals("identify", identify["type"])
        assertEquals("u1", identify["userId"])
        assertEquals(mapOf("email" to "a@b.co"), identify["traits"])
        assertEquals("u1", track["userId"])
    }

    @Test fun C04_reset_gives_new_anonymous_id_and_no_user_id() {
        val lemu = h.client()
        lemu.identify("u1", mapOf("email" to "a@b.co"))
        lemu.track("X")
        val before = lemu.anonymousId
        lemu.reset()
        lemu.track("X")
        lemu.flush()

        val batch = h.server.requests.flatMap { it.batch }
        val last = batch.last()
        assertNotEquals(before, last["anonymousId"])
        assertFalse(last.containsKey("userId"))
        assertNull(lemu.userId)
        // The new id is what a new instance on the same storage uses.
        assertEquals(last["anonymousId"], h.client().anonymousId)
    }

    @Test fun C05_purchase_is_sent_at_once() {
        val lemu = h.client()
        lemu.purchase(
            value = 1499.5,
            currency = "INR",
            orderId = "1042",
            contents = listOf(LemuContent(id = "SKU1", quantity = 1, itemPrice = 1499.5)),
            contentIds = listOf("SKU1"),
            numItems = 1,
            properties = mapOf("payment_method" to "cod"),
        )

        assertEquals(1, h.server.requests.size)
        val m = h.server.requests[0].batch.single()
        assertEquals("track", m["type"])
        assertEquals("Purchase", m["event"])
        val p = props(m)
        assertEquals(1499.5, p["value"])
        assertEquals("INR", p["currency"])
        assertEquals("1042", p["order_id"])
        assertEquals(listOf("SKU1"), p["content_ids"])
        assertEquals(1L, p["num_items"])
        assertEquals("cod", p["payment_method"])
        assertEquals(listOf(mapOf("id" to "SKU1", "quantity" to 1L, "item_price" to 1499.5)), p["contents"])
    }

    @Test fun C06_flush_threshold_of_20() {
        val lemu = h.client()
        repeat(19) { lemu.track("E$it") }
        assertEquals(0, h.server.requests.size)
        lemu.track("E19")
        assertEquals(1, h.server.requests.size)
        assertEquals(20, h.server.requests[0].batch.size)
    }

    @Test fun C07_require_consent_holds_in_memory_until_granted() {
        val lemu = h.client(requireConsent = true)
        lemu.track("X")
        lemu.flush()

        assertEquals(0, h.server.requests.size)
        assertTrue("nothing written before consent", h.storage.isEmpty())
        assertEquals(1, lemu.heldCount())

        lemu.setConsent(true)
        assertEquals(1, h.server.requests.size)
        assertEquals("X", h.server.requests[0].batch.single()["event"])
        assertEquals(lemu.anonymousId, h.storage.getString(LemuClient.KEY_ANONYMOUS_ID))
    }

    @Test fun C08_consent_withdrawn_discards_held_messages() {
        val lemu = h.client(requireConsent = true)
        lemu.track("X")
        lemu.setConsent(false)
        lemu.setConsent(true)
        lemu.flush()

        assertEquals(0, h.server.requests.size)
        assertEquals(0, lemu.heldCount())
    }

    @Test fun C09_opt_out_survives_restart_and_opt_in_resumes() {
        val lemu = h.client()
        lemu.optOut()
        lemu.track("X")
        lemu.flush()
        assertEquals(0, h.server.requests.size)

        val again = h.client()
        assertTrue(again.isOptedOut)
        again.track("X")
        again.flush()
        assertEquals(0, h.server.requests.size)

        again.optIn()
        again.track("Y")
        again.flush()
        assertEquals(1, h.server.requests.size)
        assertEquals("Y", h.server.requests[0].batch.single()["event"])
        assertFalse(h.client().isOptedOut)
    }

    @Test fun C10_retry_after_500_delivers_once_with_same_message_ids() {
        h.server.respondWith(500)
        val lemu = h.client()
        lemu.track("A")
        lemu.track("B")
        lemu.flush()
        assertEquals(1, h.server.requests.size)

        // First backoff is 1 s +/- 20%.
        h.scheduler.advance(1_300)
        assertEquals(2, h.server.requests.size)
        val (failed, ok) = h.server.requests
        assertEquals(500, failed.status)
        assertEquals(204, ok.status)
        assertEquals(failed.batch.map { it["messageId"] }, ok.batch.map { it["messageId"] })
        assertEquals(0, lemu.queuedMessages().size)

        lemu.flush()
        assertEquals("delivered once", 2, h.server.requests.size)
    }

    @Test fun C11_400_drops_the_batch() {
        for (code in listOf(400, 401, 403)) {
            h.server.requests.clear()
            h.server.respondWith(code)
            val lemu = h.client()
            lemu.track("X")
            lemu.flush()
            h.scheduler.advance(10 * 60 * 1000L)
            lemu.flush()
            assertEquals("status $code", 1, h.server.requests.size)
            assertEquals(0, lemu.queuedMessages().size)
            lemu.close()
        }
    }

    @Test fun C12_413_splits_the_batch() {
        h.server.respondWith(413)
        val lemu = h.client()
        lemu.track("A")
        lemu.track("B")
        lemu.flush()

        assertEquals(listOf(2, 1, 1), h.server.requests.map { it.batch.size })
        assertEquals(listOf("A", "B"), h.server.delivered().map { it["event"] })
    }

    @Test fun C12b_single_message_still_too_large_is_dropped() {
        h.server.defaultStatus = 413
        val lemu = h.client()
        lemu.track("A")
        lemu.flush()
        assertEquals(1, h.server.requests.size)
        assertEquals(0, lemu.queuedMessages().size)
    }

    @Test fun C13_queue_survives_restart() {
        val dir = tmp.newFolder("lemu")
        val clock = FakeClock()
        // Server down: nothing listens on the port.
        val down = FakeIngestServer().also { it.close() }
        Harness(down, FileStorage(dir), clock).use { offline ->
            val lemu = offline.client()
            lemu.track("A")
            lemu.track("B")
            lemu.track("C")
            lemu.flush()
            assertEquals(3, lemu.queuedMessages().size)
            lemu.close()
        }
        assertTrue(File(dir, "lemu-queue.jsonl").exists())

        Harness(storage = FileStorage(dir), clock = clock).use { online ->
            val lemu = online.client()
            lemu.flush()
            assertEquals(listOf("A", "B", "C"), online.server.delivered().map { it["event"] })
            online.assertAllValid()
        }
        assertEquals(emptyList<String>(), FileStorage(dir).readQueue())
    }

    @Test fun C14_queue_limit_keeps_purchase() {
        h.server.defaultStatus = 503
        val lemu = h.client()
        lemu.purchase(10.0, "INR", "order-1")
        repeat(1_000) { lemu.track("E$it") }

        val queued = lemu.queuedMessages()
        assertEquals(1_000, queued.size)
        assertTrue(queued.any { it.contains("\"event\":\"Purchase\"") })
        assertFalse("oldest non-Purchase dropped", queued.any { it.contains("\"event\":\"E0\"") })

        h.server.defaultStatus = 204
        h.scheduler.advance(10 * 60 * 1000L)
        lemu.flush()
        val delivered = h.server.delivered()
        assertEquals(1_000, delivered.size)
        assertTrue(delivered.any { it["event"] == "Purchase" })
        assertTrue(h.server.requests.all { it.batch.size <= 50 })
    }

    @Test fun C15_install_then_update() {
        val first = h.client()
        first.applicationLaunched("1.0.0", "100")
        first.flush()
        val installed = h.server.delivered().single()
        assertEquals(LemuEvent.APP_INSTALLED, installed["event"])
        assertEquals(mapOf("version" to "1.0.0", "build" to "100"), props(installed))
        first.close()

        val second = h.client()
        second.applicationLaunched("1.1.0", "110")
        second.flush()
        val updated = h.server.delivered().last()
        assertEquals(LemuEvent.APP_UPDATED, updated["event"])
        assertEquals(
            mapOf("version" to "1.1.0", "build" to "110", "previous_version" to "1.0.0", "previous_build" to "100"),
            props(updated),
        )
        second.close()

        val third = h.client()
        third.applicationLaunched("1.1.0", "110")
        third.flush()
        assertEquals("same version: no event", 2, h.server.delivered().size)
    }

    @Test fun C16_screen() {
        val lemu = h.client()
        lemu.screen("Checkout", mapOf("step" to 2))
        lemu.flush()
        val m = h.server.requests.single().batch.single()
        assertEquals("screen", m["type"])
        assertEquals("Checkout", m["name"])
        assertEquals(mapOf("step" to 2L), props(m))
    }

    @Test fun C17_invalid_arguments_never_throw() {
        val lemu = h.client()
        lemu.track("")
        lemu.track(null)
        lemu.track("   ")
        lemu.screen("")
        lemu.screen(null)
        lemu.identify(null, null)
        lemu.identify("x".repeat(300), null)
        lemu.track("WithNull", null)
        lemu.track(
            "Weird",
            mapOf(
                "nan" to Double.NaN,
                "inf" to Float.POSITIVE_INFINITY,
                "obj" to Any(),
                "nested" to mapOf("list" to arrayOf(1, null, "a"), 3 to "intKey"),
                "date" to java.util.Date(0),
                "chars" to "quote\" backslash\\ newline\n tab\t \u0001",
            ),
        )
        lemu.flush()

        val batch = h.server.requests.single().batch
        assertEquals(listOf("WithNull", "Weird"), batch.map { it["event"] })
        assertEquals(emptyMap<String, Any?>(), props(batch[0]))
        val weird = props(batch[1])
        assertNull(weird["nan"])
        assertEquals("1970-01-01T00:00:00.000Z", weird["date"])
        assertEquals("quote\" backslash\\ newline\n tab\t \u0001", weird["chars"])
        assertEquals(mapOf("list" to listOf(1L, null, "a"), "3" to "intKey"), weird["nested"])
    }

    @Test fun C17b_transport_that_throws_is_contained() {
        val lemu =
            h.client(
                transport =
                    object : HttpTransport {
                        override fun post(
                            url: String,
                            body: ByteArray,
                            headers: Map<String, String>,
                        ): HttpResult = throw IllegalStateException("boom")
                    },
            )
        lemu.track("X")
        lemu.flush()
        assertEquals(1, lemu.queuedMessages().size)
    }

    @Test fun C18_sent_at_is_set_at_send_time() {
        val lemu = h.client()
        lemu.track("X")
        h.clock.nowMillis += 5_000
        lemu.track("Y")
        h.clock.nowMillis += 5_000
        lemu.flush()

        val req = h.server.requests.single()
        val sentAt = parse(req.json["sentAt"] as String)
        val stamps = req.batch.map { parse(it["timestamp"] as String) }
        assertEquals(h.clock.nowMillis, sentAt)
        assertEquals(listOf(h.clock.nowMillis - 10_000, h.clock.nowMillis - 5_000), stamps)
        assertTrue(stamps.all { sentAt >= it })
    }

    @Test fun C19_requests_hold_at_most_50_messages() {
        val lemu = h.client(flushAt = 10_000)
        repeat(120) { lemu.track("E$it") }
        lemu.flush()
        assertEquals(listOf(50, 50, 20), h.server.requests.map { it.batch.size })
        assertEquals((0 until 120).map { "E$it" }, h.server.delivered().map { it["event"] })
    }

    @Test fun C20_event_name_constants_match_events_json() {
        val spec = Json.parse(File(sdksRoot, "spec/events.json").readText()) as Map<String, Any?>
        val names =
            (spec["meta_events"] as List<Map<String, Any?>>).map { it["name"] as String } +
                (spec["lifecycle_events"] as List<Map<String, Any?>>).map { it["name"] as String }
        val constants =
            LemuEvent::class.java.declaredFields
                .filter { java.lang.reflect.Modifier.isStatic(it.modifiers) && it.type == String::class.java }
                .associate { it.name to it.get(null) as String }
        for (name in names) {
            val expected = if (name.contains('_')) name.uppercase() else name.replace(Regex("(?<!^)(?=[A-Z])"), "_").uppercase()
            assertEquals("LemuEvent.$expected", name, constants[expected])
        }
        assertEquals("no constants beyond events.json", names.toSet(), constants.values.toSet())
        assertEquals(names, LemuEvent.META_EVENTS + LemuEvent.LIFECYCLE_EVENTS)
        assertEquals((spec["conversion"] as Map<String, Any?>)["required"], LemuEvent.CONVERSION_REQUIRED_FIELDS)
    }

    private fun parse(ts: String): Long =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.parse(ts)!!.time
}
