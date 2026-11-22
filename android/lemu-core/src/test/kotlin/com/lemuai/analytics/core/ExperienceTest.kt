package com.lemuai.analytics.core

import com.lemuai.analytics.LemuExperienceEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** In-app messages: rules (same results as the website runtime) and the engine. */
@Suppress("UNCHECKED_CAST")
class ExperienceTest {
    // ------------------------------------------------------------------ fixtures

    private fun experience(
        key: String = "welcome",
        id: Long = 42,
        format: String = "popup",
        holdout: Int = 0,
        variants: List<Map<String, Any?>> = listOf(variant("a", 50), variant("b", 50)),
        where: Map<String, Any?> = mapOf("include" to listOf(mapOf("type" to "screen_equals", "value" to "Home"))),
        who: Map<String, Any?> = mapOf("match" to "all", "conditions" to emptyList<Any>(), "server" to false, "server_conditions" to 0),
        trigger: Map<String, Any?> = mapOf("on" to "page_load"),
        frequency: Map<String, Any?> = mapOf("show" to "session", "days" to 7, "stop_after_submit" to true, "max_closes" to 2, "cooldown_hours_after_close" to 24),
        platform: String = "app",
    ): Map<String, Any?> =
        mapOf(
            "id" to id,
            "key" to key,
            "format" to format,
            "platform" to platform,
            "priority" to 100,
            "version" to 3,
            "inline" to false,
            "schedule" to emptyMap<String, Any?>(),
            "where" to where,
            "who" to who,
            "trigger" to trigger,
            "frequency" to frequency,
            "holdout_pct" to holdout,
            "capture" to mapOf("fields" to emptyMap<String, Any?>(), "offer" to false, "verify_phone" to false),
            "variants" to variants,
        )

    private fun variant(
        key: String,
        weight: Int,
    ): Map<String, Any?> =
        mapOf(
            "key" to key,
            "weight" to weight,
            "kind" to "blocks",
            "content" to
                mapOf(
                    "steps" to
                        listOf(
                            mapOf(
                                "id" to "form",
                                "blocks" to
                                    listOf(
                                        mapOf("type" to "heading", "text" to "Get **10%** off"),
                                        mapOf("type" to "field", "name" to "email", "input" to "email", "required" to true),
                                        mapOf("type" to "button", "text" to "Send", "action" to "submit"),
                                    ),
                            ),
                            mapOf("id" to "success", "blocks" to listOf(mapOf("type" to "offer"))),
                        ),
                ),
        )

    private fun bundleOf(
        vararg exps: Map<String, Any?>,
        decide: Boolean = false,
    ): Map<String, Any?> =
        mapOf(
            "live" to true,
            "v" to "abc",
            "theme" to mapOf("primary_color" to "#ff0000"),
            "caps" to mapOf("popups_per_page" to 1, "popups_per_session" to 2),
            "experiences" to exps.toList(),
            "pages" to emptyList<Any>(),
            "decide" to decide,
        )

    private fun parsed(e: Map<String, Any?>): Experience = ExperienceBundle.parse(bundleOf(e)).experiences.single()

    private class FakeHttp : ExperienceHttp {
        val gets = ArrayList<String>()
        val posts = ArrayList<Pair<String, Map<String, Any?>>>()
        var config: Map<String, Any?> = mapOf("live" to false)
        var configStatus = 200
        var decide: Map<String, Any?> = mapOf("known" to false, "experiences" to emptyMap<String, Any?>())
        var submit: Pair<Int, String> = 200 to """{"ok":true,"offer":{"code":"WELCOME10","headline":"10% off"}}"""

        override fun get(
            url: String,
            headers: Map<String, String>,
        ): ExperienceHttpReply {
            gets.add(url)
            if (configStatus == 0) return ExperienceHttpReply(0, null)
            return ExperienceHttpReply(configStatus, Json.encode(config))
        }

        override fun post(
            url: String,
            body: String,
            headers: Map<String, String>,
        ): ExperienceHttpReply {
            posts.add(url to (Json.parse(body) as Map<String, Any?>))
            return if (url.endsWith("/decide")) ExperienceHttpReply(200, Json.encode(decide)) else ExperienceHttpReply(submit.first, submit.second)
        }
    }

    private class FakeHost(override var anonymousId: String? = "visitor-1") : ExperienceHost {
        val tracked = ArrayList<Pair<String, Map<String, Any?>>>()
        override var userId: String? = null
        override var isOptedOut = false
        override var canPersist = true

        override fun track(
            event: String,
            properties: Map<String, Any?>,
        ) {
            tracked.add(event to properties)
        }

        fun names() = tracked.map { it.first }
    }

    private class FakePresenter : ExperiencePresenter {
        val shown = ArrayList<ExperienceDisplay>()
        val dismissed = ArrayList<ExperienceDisplay>()

        override fun present(display: ExperienceDisplay): Boolean {
            shown.add(display)
            return true
        }

        override fun dismiss(display: ExperienceDisplay) {
            dismissed.add(display)
        }
    }

    private inner class Setup(anonymousId: String? = "visitor-1") {
        val clock = FakeClock()
        val scheduler = ManualScheduler(clock)
        val http = FakeHttp()
        val host = FakeHost(anonymousId)
        val presenter = FakePresenter()
        val storage = InMemoryStorage()
        val events = ArrayList<LemuExperienceEvent>()
        val engine =
            ExperienceEngine(
                writeKey = "lpk_test",
                apiHost = "https://lemu.test/",
                userAgent = "lemu-android/test",
                platform = "android",
                storage = storage,
                host = host,
                presenter = presenter,
                http = http,
                clock = clock,
                scheduler = scheduler,
            ).also { e -> e.listener = { events.add(it) } }

        fun start(vararg exps: Map<String, Any?>, decide: Boolean = false): Setup {
            http.config = bundleOf(*exps, decide = decide)
            engine.start()
            return this
        }
    }

    // ------------------------------------------------------------------ hashing and variants

    @Test fun fnv1a_matches_the_website() {
        assertEquals(2166136261L, ExperienceRules.fnv1a(""))
        assertEquals(3826002220L, ExperienceRules.fnv1a("a"))
        assertEquals(335668310L, ExperienceRules.fnv1a("abc:1"))
        assertEquals(0.5043429000, ExperienceRules.bucket(""), 1e-9)
        assertEquals(0.8908105597, ExperienceRules.bucket("a"), 1e-9)
        assertEquals(0.0781538687, ExperienceRules.bucket("abc:1"), 1e-9)
        assertEquals(0.3183784358, ExperienceRules.bucket("visitor-1:42"), 1e-9)
        assertEquals(0.0275701222, ExperienceRules.bucket("3f1c2d4e-0000-4000-8000-000000000001:7"), 1e-9)
    }

    @Test fun assign_matches_the_website() {
        val exp = parsed(experience(id = 42, holdout = 10))
        val expected = listOf("a", "a", "holdout", "b", "a", "b", "b", "a", "b", "b", "b", "holdout")
        for (i in 1..12) assertEquals("visitor-$i", expected[i - 1], ExperienceRules.assign(exp, "visitor-$i", ExperienceSeen()))
        val weighted = parsed(experience(id = 7, variants = listOf(variant("control", 1), variant("new", 3))))
        val expected2 = listOf("control", "new", "new", "new", "new", "new", "new", "control", "new", "control", "control", "control")
        for (i in 1..12) assertEquals("visitor-$i", expected2[i - 1], ExperienceRules.assign(weighted, "visitor-$i", ExperienceSeen()))
    }

    @Test fun assign_is_sticky_until_the_variant_goes_away() {
        val exp = parsed(experience())
        val seen = ExperienceSeen(variant = "b")
        assertEquals("b", ExperienceRules.assign(exp, "visitor-1", seen))
        seen.variant = "gone"
        assertEquals("a", ExperienceRules.assign(exp, "visitor-1", seen))
        assertEquals("a", seen.variant)
        seen.variant = "holdout" // holdout removed: assigned again
        assertEquals("a", ExperienceRules.assign(exp, "visitor-1", seen))
    }

    // ------------------------------------------------------------------ compare and rules

    @Test fun compare_follows_the_server_rules() {
        assertTrue(ExperienceRules.compare("Returning", null, "returning"))
        assertTrue(ExperienceRules.compare(3L, "gte", 2))
        assertFalse(ExperienceRules.compare(1L, "gt", "x"))
        assertTrue(ExperienceRules.compare(2L, "eq", 2.0))
        assertTrue(ExperienceRules.compare("b", "in", "a, b ,c"))
        assertTrue(ExperienceRules.compare("z", "not_in", listOf("a", "b")))
        assertTrue(ExperienceRules.compare("Hello World", "contains", "world"))
        assertTrue(ExperienceRules.compare(true, "eq", "yes"))
        assertTrue(ExperienceRules.compare(false, "neq", true))
        assertTrue(ExperienceRules.compare("", "not_exists", null))
        assertFalse(ExperienceRules.compare(emptyList<Any>(), "exists", null))
        assertTrue(ExperienceRules.sameEvent("add_to_cart", "AddToCart"))
        assertTrue(ExperienceRules.sameEvent("Sign Up", "sign-up"))
        assertFalse(ExperienceRules.sameEvent("", ""))
    }

    @Test fun where_matches_screens_ignoring_case() {
        val home = parsed(experience())
        assertTrue(ExperienceRules.whereMatches(home, "home"))
        assertFalse(ExperienceRules.whereMatches(home, "Cart"))
        val prefix =
            parsed(
                experience(
                    where =
                        mapOf(
                            "include" to listOf(mapOf("type" to "screen_prefix", "value" to "Product")),
                            "exclude" to listOf(mapOf("type" to "screen_equals", "value" to "ProductReviews")),
                        ),
                ),
            )
        assertTrue(ExperienceRules.whereMatches(prefix, "ProductDetail"))
        assertFalse(ExperienceRules.whereMatches(prefix, "ProductReviews"))
        val any = parsed(experience(where = emptyMap()))
        assertTrue(ExperienceRules.whereMatches(any, ""))
        val web = parsed(experience(where = mapOf("include" to listOf(mapOf("type" to "path_prefix", "value" to "/")))))
        assertFalse(ExperienceRules.whereMatches(web, "Home"))
    }

    @Test fun who_checks_app_conditions_and_the_server_answer() {
        val state = ExperienceState(visits = 1)
        fun who(
            match: String,
            conditions: List<Map<String, Any?>>,
            server: Int = 0,
        ) = parsed(experience(who = mapOf("match" to match, "conditions" to conditions, "server" to (server > 0), "server_conditions" to server)))
        val returning = who("all", listOf(mapOf("kind" to "visitor", "op" to "eq", "value" to "returning")))
        assertFalse(ExperienceRules.whoMatches(returning, null, null, state))
        state.visits = 3
        assertTrue(ExperienceRules.whoMatches(returning, null, null, state))
        val identified = who("all", listOf(mapOf("kind" to "identified", "op" to "eq", "value" to null)))
        assertFalse(ExperienceRules.whoMatches(identified, null, null, state))
        assertTrue(ExperienceRules.whoMatches(identified, null, "u1", state))
        // Browser-only conditions are left out in apps.
        val device = who("all", listOf(mapOf("kind" to "device", "op" to "eq", "value" to "desktop")))
        assertTrue(ExperienceRules.whoMatches(device, null, null, state))
        val anyOf = who("any", listOf(mapOf("kind" to "visit_count", "op" to "gt", "value" to 10)), server = 1)
        assertFalse(ExperienceRules.whoMatches(anyOf, null, null, state))
        val yes = ExperienceDecision(true, mapOf("welcome" to ExperienceDecision.Answer(true, false)))
        val hidden = ExperienceDecision(true, mapOf("welcome" to ExperienceDecision.Answer(true, true)))
        assertTrue(ExperienceRules.whoMatches(anyOf, yes, null, state))
        assertFalse(ExperienceRules.whoMatches(anyOf, hidden, null, state))
        val allOf = who("all", emptyList(), server = 1)
        val no = ExperienceDecision(true, mapOf("welcome" to ExperienceDecision.Answer(false, false)))
        assertFalse(ExperienceRules.whoMatches(allOf, no, null, state))
        assertTrue(ExperienceRules.whoMatches(allOf, yes, null, state))
    }

    @Test fun frequency_follows_the_website() {
        val now = 1_795_428_000_000L
        val state = ExperienceState(session = "s1")
        val session = parsed(experience())
        assertTrue(ExperienceRules.frequencyAllows(session, ExperienceSeen(), state, now))
        assertFalse(ExperienceRules.frequencyAllows(session, ExperienceSeen(n = 1, last = now, sessionShown = "s1"), state, now))
        assertTrue(ExperienceRules.frequencyAllows(session, ExperienceSeen(n = 1, last = now, sessionShown = "s0"), state, now))
        assertFalse(ExperienceRules.frequencyAllows(session, ExperienceSeen(submitted = now - 1), state, now))
        assertFalse(ExperienceRules.frequencyAllows(session, ExperienceSeen(closes = 2, lastClose = 1), state, now))
        val hour = 3_600_000L
        assertFalse(ExperienceRules.frequencyAllows(session, ExperienceSeen(closes = 1, lastClose = now - 23 * hour), state, now))
        assertTrue(ExperienceRules.frequencyAllows(session, ExperienceSeen(closes = 1, lastClose = now - 25 * hour), state, now))
        val days = parsed(experience(frequency = mapOf("show" to "days", "days" to 3, "stop_after_submit" to false, "max_closes" to null, "cooldown_hours_after_close" to 0)))
        assertFalse(ExperienceRules.frequencyAllows(days, ExperienceSeen(n = 1, last = now - 2 * 24 * hour, submitted = 1), state, now))
        assertTrue(ExperienceRules.frequencyAllows(days, ExperienceSeen(n = 1, last = now - 4 * 24 * hour, submitted = 1), state, now))
        val ever = parsed(experience(frequency = mapOf("show" to "ever", "stop_after_submit" to true, "max_closes" to null, "cooldown_hours_after_close" to 24)))
        assertFalse(ExperienceRules.frequencyAllows(ever, ExperienceSeen(n = 1, last = 1), state, now))
        val always = parsed(experience(frequency = mapOf("show" to "always", "stop_after_submit" to false, "max_closes" to null, "cooldown_hours_after_close" to 0)))
        assertTrue(ExperienceRules.frequencyAllows(always, ExperienceSeen(n = 9, last = now, closes = 5, lastClose = now), state, now))
    }

    @Test fun schedule_checks_dates_days_and_hours() {
        val monday10utc = 1_795_428_000_000L // 2026-11-23T10:00:00Z, a Monday
        assertEquals(monday10utc, ExperienceRules.parseIso("2026-11-23T10:00:00Z"))
        assertEquals(monday10utc, ExperienceRules.parseIso("2026-11-23T15:30:00.000+05:30"))
        assertNull(ExperienceRules.parseIso("next week"))
        assertTrue(ExperienceRules.scheduleOpen(emptyMap(), monday10utc))
        assertFalse(ExperienceRules.scheduleOpen(mapOf("start" to "2026-11-24T00:00:00Z"), monday10utc))
        assertFalse(ExperienceRules.scheduleOpen(mapOf("end" to "2026-11-23T10:00:00Z"), monday10utc))
        assertTrue(ExperienceRules.scheduleOpen(mapOf("timezone" to "UTC", "days_of_week" to listOf(0, 1)), monday10utc))
        assertFalse(ExperienceRules.scheduleOpen(mapOf("timezone" to "UTC", "days_of_week" to listOf(5, 6)), monday10utc))
        assertTrue(ExperienceRules.scheduleOpen(mapOf("timezone" to "UTC", "hours" to mapOf("from" to "09:00", "to" to "21:00")), monday10utc))
        assertFalse(ExperienceRules.scheduleOpen(mapOf("timezone" to "UTC", "hours" to mapOf("from" to "11:00", "to" to "21:00")), monday10utc))
        // 15:30 in Kolkata (the default time zone).
        assertFalse(ExperienceRules.scheduleOpen(mapOf("hours" to mapOf("from" to "09:00", "to" to "15:00")), monday10utc))
        // Overnight window.
        assertTrue(ExperienceRules.scheduleOpen(mapOf("timezone" to "UTC", "hours" to mapOf("from" to "22:00", "to" to "11:00")), monday10utc))
    }

    // ------------------------------------------------------------------ bundle, content, state

    @Test fun bundle_parsing_keeps_only_app_experiences() {
        assertFalse(ExperienceBundle.parse(mapOf("live" to false)).live)
        assertTrue(ExperienceBundle.parse(mapOf("live" to false)).experiences.isEmpty())
        assertFalse(ExperienceBundle.parse("nonsense").live)
        val b =
            ExperienceBundle.parse(
                bundleOf(
                    experience(key = "a"),
                    experience(key = "web", platform = "web"),
                    experience(key = "inline", format = "inline"),
                    experience(key = "toast", format = "toast", platform = "any"),
                ),
            )
        assertEquals(listOf("a", "toast"), b.experiences.map { it.key })
        assertEquals(1, b.popupsPerPage)
        assertEquals(2, b.popupsPerSession)
        val exp = b.find("a")!!
        assertEquals(42L, exp.id)
        assertEquals("page_load", exp.trigger.on)
        assertEquals(2, exp.frequency.maxCloses)
        assertEquals(2, ExperienceStep.of(exp.variants[0].content).size)
    }

    @Test fun content_helpers() {
        assertEquals("Get 10% off now, see terms", ExperienceText.plain("Get **10%** off *now*, see [terms](https://x.test)"))
        assertEquals("Code WELCOME10 for a@b.co", ExperienceText.fill("Code {{offer.code}} for {{ answers.email }}{{x.y}}", mapOf("offer" to mapOf("code" to "WELCOME10"), "answers" to mapOf("email" to "a@b.co"))))
        val email = ExperienceField.of(mapOf("name" to "email", "input" to "email", "required" to true))!!
        val phone = ExperienceField.of(mapOf("name" to "phone", "input" to "phone"))!!
        val consent = ExperienceField.of(mapOf("name" to "ok", "input" to "consent", "required" to true))!!
        val fields = listOf(email, phone, consent)
        assertEquals(ExperienceText.ERROR_REQUIRED, ExperienceText.validate(fields, mapOf("email" to "", "ok" to true)))
        assertEquals(ExperienceText.ERROR_REQUIRED, ExperienceText.validate(fields, mapOf("email" to "a@b.co", "ok" to false)))
        assertEquals(ExperienceText.ERROR_EMAIL, ExperienceText.validate(fields, mapOf("email" to "a@b", "ok" to true)))
        assertEquals(ExperienceText.ERROR_PHONE, ExperienceText.validate(fields, mapOf("email" to "a@b.co", "phone" to "123", "ok" to true)))
        assertNull(ExperienceText.validate(fields, mapOf("email" to "a@b.co", "phone" to "98765 43210", "ok" to true)))
        assertEquals("+919876543210", ExperienceText.phoneValue("09876 543210", "+91"))
        assertEquals("+14155550100", ExperienceText.phoneValue("+1 415 555 0100", "+91"))
        assertEquals("+91", phone.defaultCountry)
        assertEquals(11, ExperienceField.of(mapOf("name" to "nps", "input" to "nps"))!!.options.size)
        val chips = ExperienceField.of(mapOf("name" to "size", "input" to "chips", "options" to listOf("S", mapOf("value" to "M", "label" to "Medium"))))!!
        assertEquals(listOf("S", "Medium"), chips.options.map { it.label })
        val steps = listOf(ExperienceStep("q", listOf(mapOf("type" to "field"))), ExperienceStep("form", listOf(mapOf("type" to "field"))), ExperienceStep("done", emptyList()))
        assertEquals(2, ExperienceText.stepAfterSubmit(steps, 0))
        assertEquals(-1, ExperienceText.stepAfterSubmit(steps.take(2), 0))
        assertEquals(0xFFFF0000.toInt(), ExperienceTheme.parseColor("#f00"))
        assertEquals(0x80112233.toInt(), ExperienceTheme.parseColor("#11223380"))
        assertEquals(0x8C111827.toInt(), ExperienceTheme.parseColor("rgba(17,24,39,0.55)"))
        assertNull(ExperienceTheme.parseColor("blue"))
        val theme = ExperienceTheme.from(mapOf("primary_color" to "#ff0000", "button_style" to "pill"), mapOf("background" to "#000000"))
        assertEquals(0xFFFF0000.toInt(), theme.primary)
        assertEquals(0xFF000000.toInt(), theme.background)
        assertEquals(999f, theme.buttonRadius)
    }

    @Test fun submit_answers() {
        assertEquals(ExperienceText.ERROR_NETWORK, ExperienceSubmitResult.from(0, null).error)
        assertEquals(ExperienceText.ERROR_RATE_LIMIT, ExperienceSubmitResult.from(429, "{}").error)
        assertEquals("Bad email", ExperienceSubmitResult.from(400, """{"ok":false,"errors":{"email":"Bad email"}}""").error)
        val otp = ExperienceSubmitResult.from(200, """{"ok":false,"verify":true,"errors":{"_otp":"Wrong code"}}""")
        assertTrue(otp.verify)
        assertEquals("Wrong code", otp.error)
        val ok = ExperienceSubmitResult.from(200, """{"ok":true,"offer":{"code":"X1","terms":"Today only"}}""")
        assertTrue(ok.ok)
        assertEquals("X1", ok.offer?.code)
    }

    @Test fun state_round_trips_and_starts_sessions() {
        val s = ExperienceState()
        assertTrue(s.touch(1_000_000L))
        assertEquals(1L, s.visits)
        assertEquals(8, s.session.length)
        assertFalse(s.touch(1_000_000L + 60_000L))
        assertTrue(s.touch(1_000_000L + 60_000L + ExperienceState.SESSION_GAP_MS + 1))
        assertEquals(2L, s.visits)
        s.seen("welcome").apply {
            n = 2
            variant = "b"
        }
        val back = ExperienceState.fromJson(s.toJson())
        assertEquals(2L, back.visits)
        assertEquals(s.session, back.session)
        assertEquals("b", back.seen["welcome"]?.variant)
        assertEquals(2L, back.seen["welcome"]?.n)
        assertEquals(0L, ExperienceState.fromJson("{broken").visits)
    }

    // ------------------------------------------------------------------ engine

    @Test fun page_load_on_a_matching_screen_shows_and_tracks() {
        val t = Setup().start(experience())
        assertEquals(listOf("https://lemu.test/api/v1/pixel/onsite/config?k=lpk_test"), t.http.gets)
        assertTrue(t.presenter.shown.isEmpty()) // no screen yet
        t.engine.onScreen("Cart")
        assertTrue(t.presenter.shown.isEmpty())
        t.engine.onScreen("Home")
        assertEquals(1, t.presenter.shown.size)
        val display = t.presenter.shown[0]
        assertEquals("a", display.variant.key)
        assertEquals(0xFFFF0000.toInt(), display.theme.primary)
        assertEquals(listOf("onsite_viewed"), t.host.names())
        assertEquals(
            mapOf("experience_id" to 42L, "experience" to "welcome", "variant" to "a", "version" to 3L, "format" to "popup", "screen" to "Home"),
            t.host.tracked[0].second,
        )
        assertEquals(LemuExperienceEvent.Type.SHOWN, t.events.single().type)
        // Saved history.
        val saved = ExperienceState.fromJson(t.storage.getString(ExperienceState.KEY))
        assertEquals(1L, saved.seen["welcome"]?.n)
        assertEquals("a", saved.seen["welcome"]?.variant)

        display.close(true)
        assertEquals("onsite_closed", t.host.names().last())
        assertEquals(LemuExperienceEvent.Type.CLOSED, t.events.last().type)
        assertTrue(t.events.last().byUser)
        t.engine.onScreen("Home") // shown this session already
        assertEquals(1, t.presenter.shown.size)
    }

    @Test fun holdout_tracks_held_out_once_and_shows_nothing() {
        val t = Setup(anonymousId = "visitor-3").start(experience(holdout = 10))
        t.engine.onScreen("Home")
        t.engine.onScreen("Home")
        assertTrue(t.presenter.shown.isEmpty())
        assertEquals(listOf("onsite_held_out"), t.host.names())
        assertEquals("holdout", t.host.tracked[0].second["variant"])
        assertFalse(t.engine.show("welcome"))
    }

    @Test fun event_and_delay_triggers() {
        val t =
            Setup().start(
                experience(key = "cart", trigger = mapOf("on" to "event", "event" to "add_to_cart"), where = emptyMap()),
                experience(key = "later", format = "toast", trigger = mapOf("on" to "delay", "seconds" to 5), where = emptyMap()),
            )
        t.engine.onTrack("onsite_viewed", null)
        t.engine.onTrack("AddToCart", mapOf("value" to 10))
        assertEquals(listOf("cart"), t.presenter.shown.map { it.experience.key })
        t.engine.hide()
        assertEquals(1, t.presenter.dismissed.size)
        assertFalse(t.events.last().byUser)
        t.engine.onScreen("Home")
        t.scheduler.advance(4_000)
        assertEquals(1, t.presenter.shown.size)
        t.scheduler.advance(1_500)
        assertEquals(listOf("cart", "later"), t.presenter.shown.map { it.experience.key })
    }

    @Test fun disabled_pauses_automatic_messages_but_not_show() {
        val t = Setup().start(experience(), experience(key = "manual", trigger = mapOf("on" to "manual")))
        t.engine.enabled = false
        t.engine.onScreen("Home")
        assertTrue(t.presenter.shown.isEmpty())
        assertTrue(t.engine.show("manual"))
        assertFalse(t.engine.show("manual")) // one at a time
        assertFalse(t.engine.show("unknown"))
    }

    @Test fun show_before_the_config_arrives_runs_once_it_does() {
        val t = Setup()
        t.http.configStatus = 0 // offline at launch
        t.start(experience(key = "manual", trigger = mapOf("on" to "manual")))
        assertFalse(t.engine.show("manual")) // nothing loaded yet: remembered
        assertTrue(t.presenter.shown.isEmpty())
        t.http.configStatus = 200
        t.engine.refresh()
        assertEquals(listOf("manual"), t.presenter.shown.map { it.experience.key })
        assertEquals(2, t.http.gets.size)
    }

    @Test fun server_rules_ask_decide_first() {
        val who = mapOf("match" to "all", "conditions" to emptyList<Any>(), "server" to true, "server_conditions" to 1)
        val t = Setup()
        t.http.decide = mapOf("known" to true, "experiences" to mapOf("welcome" to mapOf("match" to true, "hidden" to false)))
        t.start(experience(who = who), decide = true)
        t.engine.onTrack("ViewContent", mapOf("content_ids" to listOf("SKU1")))
        t.engine.onScreen("Home")
        // A new screen clears the product.
        val decide = t.http.posts.single { it.first.endsWith("/decide") }.second
        assertEquals("lpk_test", decide["writeKey"])
        assertEquals("visitor-1", decide["anonymousId"])
        assertEquals(mapOf("screen" to "Home", "product" to emptyMap<String, Any?>()), decide["context"])
        assertEquals(1, t.presenter.shown.size)

        val hidden = Setup()
        hidden.http.decide = mapOf("known" to true, "experiences" to mapOf("welcome" to mapOf("match" to true, "hidden" to true)))
        hidden.start(experience(who = who), decide = true)
        hidden.engine.onScreen("Home")
        assertTrue(hidden.presenter.shown.isEmpty())
    }

    @Test fun submit_posts_the_form_and_remembers_it() {
        val t = Setup().start(experience())
        t.engine.onScreen("Home")
        val display = t.presenter.shown.single()
        var result: ExperienceSubmitResult? = null
        display.submit(mapOf("email" to "a@b.co"), null, null) { result = it }
        assertNotNull(result)
        assertTrue(result!!.ok)
        assertEquals("WELCOME10", result!!.offer?.code)
        val (url, body) = t.http.posts.single()
        assertEquals("https://lemu.test/api/v1/pixel/onsite/submit", url)
        assertEquals("welcome", body["experience"])
        assertEquals("a", body["variant"])
        assertEquals(mapOf("email" to "a@b.co"), body["fields"])
        assertEquals(mapOf("screen" to "Home", "platform" to "android", "phone_country" to "+91"), body["context"])
        assertFalse(body.containsKey("otp"))
        val submitted = t.events.last()
        assertEquals(LemuExperienceEvent.Type.SUBMITTED, submitted.type)
        assertEquals("WELCOME10", submitted.offerCode)
        assertTrue(ExperienceState.fromJson(t.storage.getString(ExperienceState.KEY)).seen["welcome"]!!.submitted > 0)
    }

    @Test fun opted_out_and_consent() {
        val t = Setup()
        t.host.isOptedOut = true
        t.start(experience())
        t.engine.onScreen("Home")
        assertTrue(t.presenter.shown.isEmpty())

        val pending = Setup()
        pending.host.canPersist = false
        pending.start(experience())
        pending.engine.onScreen("Home")
        assertEquals(1, pending.presenter.shown.size)
        assertNull(pending.storage.getString(ExperienceState.KEY))
    }

    @Test fun clicks_are_tracked_with_the_target() {
        val t = Setup().start(experience())
        t.engine.onScreen("Home")
        t.presenter.shown.single().clicked("https://shop.test/sale")
        val (name, props) = t.host.tracked.last()
        assertEquals("onsite_clicked", name)
        assertEquals("https://shop.test/sale", props["target"])
        assertEquals(LemuExperienceEvent.Type.CLICKED, t.events.last().type)
    }
}
