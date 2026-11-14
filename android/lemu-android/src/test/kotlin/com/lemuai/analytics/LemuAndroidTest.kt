package com.lemuai.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM unit tests for the Android layer (android.jar methods return defaults here). */
class LemuAndroidTest {
    @Test fun device_type_uses_smallest_width() {
        assertEquals("phone", AndroidContext.deviceTypeForWidth(411))
        assertEquals("tablet", AndroidContext.deviceTypeForWidth(600))
        assertEquals("tablet", AndroidContext.deviceTypeForWidth(800))
    }

    @Test fun options_defaults_and_builder() {
        val d = LemuOptions()
        assertEquals("https://app.lemuai.com", d.apiHost)
        assertTrue(d.trackLifecycleEvents)
        assertFalse(d.trackActivityScreens)
        assertEquals(20, d.flushAt)
        assertEquals(30, d.flushIntervalSeconds)
        val b = LemuOptions.builder().debug(true).requireConsent(true).flushAt(5).build()
        assertTrue(b.debug)
        assertTrue(b.requireConsent)
        assertEquals(5, b.flushAt)
    }

    @Test fun calls_before_setup_are_ignored() {
        Lemu.track("X")
        Lemu.purchase(1.0, "INR", "o1")
        Lemu.flush()
        assertNull(Lemu.anonymousId)
        assertFalse(Lemu.isSetUp)
    }
}
