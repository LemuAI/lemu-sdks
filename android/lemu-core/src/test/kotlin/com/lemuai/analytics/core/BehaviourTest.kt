package com.lemuai.analytics.core

import com.lemuai.analytics.LemuEvent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import kotlin.random.Random

/** Protocol behaviour beyond the numbered conformance scenarios. */
@Suppress("UNCHECKED_CAST")
class BehaviourTest {
    @get:Rule val tmp = TemporaryFolder()

    private val h = Harness()

    @After fun tearDown() {
        h.assertAllValid()
        h.close()
    }

    private fun campaign(m: Map<String, Any?>) = (m["context"] as Map<String, Any?>)["campaign"]

    @Test fun backoff_doubles_with_jitter_and_caps_at_five_minutes() {
        val lemu = h.client()
        for (attempt in 0 until 30) {
            val base = minOf(300_000L, 1_000L shl minOf(attempt, 20))
            repeat(20) {
                val d = lemu.backoffDelay(attempt)
                assertTrue("attempt $attempt: $d", d >= (base * 0.8).toLong() && d <= (base * 1.2).toLong() + 1)
            }
        }
    }

    @Test fun retries_429_and_network_errors() {
        h.server.respondWith(429, 503)
        val lemu = h.client()
        lemu.track("X")
        lemu.flush()
        h.scheduler.advance(1_300)
        h.scheduler.advance(2_500)
        assertEquals(listOf(429, 503, 204), h.server.requests.map { it.status })
        assertEquals(1, h.server.delivered().size)
    }

    @Test fun flush_waits_for_backoff() {
        h.server.respondWith(500)
        val lemu = h.client()
        lemu.track("X")
        lemu.flush()
        lemu.flush()
        lemu.purchase(1.0, "INR", "o1")
        assertEquals("no request during backoff", 1, h.server.requests.size)
        h.scheduler.advance(1_300)
        assertEquals(listOf("X", "Purchase"), h.server.delivered().map { it["event"] })
    }

    @Test fun periodic_flush_every_30_seconds() {
        val lemu = h.client()
        lemu.track("X")
        h.scheduler.advance(29_000)
        assertEquals(0, h.server.requests.size)
        h.scheduler.advance(1_000)
        assertEquals(1, h.server.requests.size)
        lemu.track("Y")
        h.scheduler.advance(30_000)
        assertEquals(2, h.server.requests.size)
    }

    @Test fun gives_up_20_hours_after_first_attempt() {
        h.server.defaultStatus = 500
        val lemu = h.client()
        lemu.track("X")
        lemu.flush()
        h.scheduler.advance(19 * 3_600_000L)
        assertEquals(1, lemu.queuedMessages().size)
        h.scheduler.advance(2 * 3_600_000L)
        assertEquals(0, lemu.queuedMessages().size)
        val attempts = h.server.requests.size
        h.scheduler.advance(3_600_000L)
        assertEquals("no more attempts", attempts, h.server.requests.size)
    }

    @Test fun offline_messages_are_kept_and_dropped_after_7_days() {
        val down = FakeIngestServer().also { it.close() }
        val storage = InMemoryStorage()
        val clock = FakeClock()
        Harness(down, storage, clock).use { offline ->
            val lemu = offline.client()
            lemu.track("Old")
            lemu.flush()
            // Connection refused never reached the server, so the 20 hour limit does not apply.
            offline.scheduler.advance(2 * 24 * 3_600_000L)
            assertEquals(1, lemu.queuedMessages().size)
            offline.scheduler.advance(6 * 24 * 3_600_000L)
            lemu.track("New")
            lemu.flush()
            assertEquals(listOf("New"), lemu.queuedMessages().map { (Json.parse(it) as Map<String, Any?>)["event"] })
            lemu.close()
        }
    }

    @Test fun purchase_via_track_also_flushes_and_warns_without_fields() {
        val lemu = h.client()
        lemu.track(LemuEvent.PURCHASE, mapOf("value" to 10))
        assertEquals(1, h.server.requests.size)
        assertTrue(h.logger.lines.any { it.contains("WARN Purchase without currency, order_id") })
    }

    @Test fun deep_link_sets_campaign_for_later_messages() {
        val lemu = h.client()
        lemu.track("Before")
        lemu.deepLinkOpened("brand://product/1?utm_source=google&utm_medium=cpc&utm_campaign=diwali&gclid=abc&other=1", "android-app://com.google.android.gm")
        lemu.track("After")
        lemu.flush()
        val (before, link, after) = h.server.requests.single().batch
        assertNull(campaign(before))
        assertEquals(LemuEvent.DEEP_LINK_OPENED, link["event"])
        assertEquals("android-app://com.google.android.gm", (link["properties"] as Map<String, Any?>)["referrer"])
        val expected = mapOf("source" to "google", "medium" to "cpc", "campaign" to "diwali", "gclid" to "abc")
        assertEquals(expected, campaign(link))
        assertEquals(expected, campaign(after))
    }

    @Test fun install_referrer_fills_campaign_on_first_launch() {
        val lemu = h.client(installReferrer = InstallReferrerSource { it("utm_source=facebook&utm_medium=paid&utm_campaign=diwali%20sale&fbclid=f1") })
        lemu.applicationLaunched("1.0", "1")
        lemu.flush()
        val m = h.server.delivered().single()
        assertEquals(LemuEvent.APP_INSTALLED, m["event"])
        assertEquals(mapOf("source" to "facebook", "medium" to "paid", "campaign" to "diwali sale", "fbclid" to "f1"), campaign(m))
    }

    @Test fun install_is_sent_without_referrer_after_timeout() {
        val lemu = h.client(installReferrer = InstallReferrerSource { /* never answers */ })
        lemu.applicationLaunched("1.0", "1")
        lemu.flush()
        assertEquals(0, h.server.requests.size)
        h.scheduler.advance(LemuConfig.INSTALL_REFERRER_TIMEOUT_MILLIS)
        lemu.flush()
        assertEquals(LemuEvent.APP_INSTALLED, h.server.delivered().single()["event"])
    }

    @Test fun lifecycle_open_and_background() {
        val lemu = h.client()
        lemu.applicationOpened(fromBackground = false, url = "brand://home")
        lemu.applicationBackgrounded()
        val batch = h.server.requests.single().batch
        assertEquals(listOf(LemuEvent.APP_OPENED, LemuEvent.APP_BACKGROUNDED), batch.map { it["event"] })
        assertEquals(mapOf("from_background" to false, "url" to "brand://home"), batch[0]["properties"])
    }

    @Test fun install_with_consent_pending_is_held_and_version_saved_on_consent() {
        val lemu = h.client(requireConsent = true)
        lemu.applicationLaunched("1.0", "1")
        assertTrue(h.storage.isEmpty())
        lemu.setConsent(true)
        assertEquals(LemuEvent.APP_INSTALLED, h.server.delivered().single()["event"])
        assertEquals("1.0", h.storage.getString(LemuClient.KEY_APP_VERSION))
        // Consent is remembered.
        val next = h.client(requireConsent = true)
        next.track("X")
        next.flush()
        assertEquals(2, h.server.delivered().size)
    }

    @Test fun held_messages_capped_at_50() {
        val lemu = h.client(requireConsent = true)
        repeat(60) { lemu.track("E$it") }
        assertEquals(50, lemu.heldCount())
        lemu.setConsent(true)
        assertEquals((10 until 60).map { "E$it" }, h.server.delivered().map { it["event"] })
    }

    @Test fun opt_out_clears_queue() {
        h.server.defaultStatus = 503
        val lemu = h.client()
        lemu.track("X")
        lemu.flush()
        lemu.optOut()
        assertEquals(0, lemu.queuedMessages().size)
        assertEquals(emptyList<String>(), h.storage.readQueue())
    }

    @Test fun user_id_survives_restart_until_reset() {
        val lemu = h.client()
        lemu.identify("u9", mapOf("phone" to "+919999999999"))
        val next = h.client()
        assertEquals("u9", next.userId)
        assertEquals(lemu.anonymousId, next.anonymousId)
        next.reset()
        assertNull(h.client().userId)
    }

    @Test fun batches_respect_the_byte_budget() {
        val lemu = h.client(flushAt = 10_000)
        val big = "x".repeat(60_000)
        repeat(6) { lemu.track("Big$it", mapOf("blob" to big)) }
        lemu.flush()
        assertTrue(h.server.requests.size >= 2)
        assertTrue(h.server.requests.all { it.body.toByteArray().size < 256 * 1024 })
        assertEquals(6, h.server.delivered().size)
    }

    @Test fun file_storage_round_trip_and_corrupt_lines() {
        val dir = tmp.newFolder("s")
        val s = FileStorage(dir)
        assertTrue(s.isEmpty())
        s.putString("a", "1")
        s.appendQueue("x")
        s.appendQueue("y")
        assertEquals(listOf("x", "y"), FileStorage(dir).readQueue())
        assertEquals("1", FileStorage(dir).getString("a"))
        s.remove("a")
        assertNull(FileStorage(dir).getString("a"))
        s.writeQueue(emptyList())
        assertEquals(emptyList<String>(), FileStorage(dir).readQueue())

        // A corrupt queue line is skipped, the rest is sent.
        val store = FileStorage(tmp.newFolder("q"))
        store.appendQueue("garbage line")
        Harness(storage = store).use { hh ->
            val lemu = hh.client()
            lemu.track("Ok")
            lemu.flush()
            assertEquals(listOf("Ok"), hh.server.delivered().map { it["event"] })
        }
    }

    @Test fun no_advertising_ids_even_from_a_custom_context() {
        val lemu =
            LemuClient(
                LemuConfig(writeKey = "pk", apiHost = h.server.url, userAgent = TEST_UA),
                InMemoryStorage(),
                contextProvider = { mapOf("advertisingId" to "x", "gaid" to "y") },
                clock = h.clock,
                scheduler = h.scheduler,
                random = Random(1),
            )
        lemu.track("X")
        lemu.flush()
        val ctx = h.server.requests.single().batch.single()["context"] as Map<String, Any?>
        assertFalse(ctx.containsKey("advertisingId"))
        assertFalse(ctx.containsKey("gaid"))
    }

    @Test fun schema_check_rejects_bad_bodies() {
        val bad =
            """{"writeKey":"pk","sentAt":"2026-11-14T10:00:00.000Z","batch":[{"type":"track","messageId":"not-a-uuid",""" +
                """"anonymousId":"a","timestamp":"2026-11-14T10:00:00.000Z","event":"X","properties":{},"context":{"platform":"android","library":{"name":"l","version":"1"}}}]}"""
        var failed = false
        try {
            BatchSchema.assertValid(bad)
        } catch (_: AssertionError) {
            failed = true
        }
        assertTrue("validator must reject a bad messageId", failed)
    }

    @Test fun campaign_parser() {
        assertEquals(mapOf("source" to "a b", "content" to "c"), Campaign.fromUrl("https://x.com/p?utm_source=a+b&utm_content=c#frag"))
        assertEquals(emptyMap<String, String>(), Campaign.fromUrl("brand://home"))
        assertEquals(mapOf("source" to "google-play", "medium" to "organic"), Campaign.fromQuery("utm_source=google-play&utm_medium=organic"))
    }

    @Test fun json_round_trip() {
        val v = mapOf("s" to "héllo \"q\" \\  ", "n" to 1.5, "i" to 3, "b" to true, "z" to null, "l" to listOf(1, "x"))
        val parsed = Json.parse(Json.encode(v)) as Map<String, Any?>
        assertEquals("héllo \"q\" \\  ", parsed["s"])
        assertEquals(1.5, parsed["n"])
        assertEquals(3L, parsed["i"])
        assertEquals(true, parsed["b"])
        assertTrue(parsed.containsKey("z"))
        assertEquals(listOf(1L, "x"), parsed["l"])
        assertEquals("1e-7", Json.encode(1e-7).lowercase().replace(".0e", "e"))
    }
}
