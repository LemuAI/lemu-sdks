import Foundation
import Testing
@testable import LemuAnalytics

// MARK: - Helpers

private func experience(_ overrides: [String: Any] = [:]) -> Experience {
    var json: [String: Any] = [
        "id": 42, "key": "welcome", "format": "popup", "platform": "app", "version": 3,
        "schedule": [String: Any](),
        "where": ["include": [["type": "any"]]],
        "who": ["match": "all", "conditions": [Any](), "server": false, "server_conditions": 0],
        "trigger": ["on": "page_load"],
        "frequency": ["show": "session", "stop_after_submit": true, "max_closes": 2, "cooldown_hours_after_close": 24],
        "holdout_pct": 0,
        "variants": [["key": "a", "weight": 100, "kind": "blocks", "content": [
            "steps": [
                ["id": "form", "blocks": [
                    ["type": "heading", "text": "Get **10%** off"],
                    ["type": "field", "name": "email", "input": "email", "required": true],
                    ["type": "field", "name": "phone", "input": "phone", "default_country": "+91"],
                    ["type": "button", "text": "Send", "action": "submit"],
                ]],
                ["id": "success", "blocks": [["type": "text", "text": "Your code is {{offer.code}}"], ["type": "offer"]]],
            ],
        ]]],
    ]
    for (k, v) in overrides { json[k] = v }
    return Experience(json)
}

private func bundleJSON(_ experiences: [[String: Any]], decide: Bool = false) -> [String: Any] {
    return ["live": true, "v": "abc", "theme": ["primary_color": "#ff0000"], "caps": ["popups_per_page": 1, "popups_per_session": 2],
            "experiences": experiences, "pages": [Any](), "decide": decide]
}

private func experienceJSON(_ key: String, id: Int = 1, format: String = "popup", trigger: [String: Any] = ["on": "page_load"],
                            include: [[String: Any]] = [["type": "any"]], who: [String: Any]? = nil,
                            frequency: [String: Any] = ["show": "session"], holdout: Int = 0) -> [String: Any]
{
    return [
        "id": id, "key": key, "format": format, "platform": "app", "version": 1, "schedule": [String: Any](),
        "where": ["include": include], "who": who ?? ["match": "all", "conditions": [Any](), "server": false, "server_conditions": 0],
        "trigger": trigger, "frequency": frequency, "holdout_pct": holdout,
        "variants": [["key": "a", "weight": 100, "kind": "blocks", "content": ["steps": [
            ["id": "s1", "blocks": [["type": "heading", "text": "Hello"], ["type": "button", "text": "OK", "action": "close"]]],
        ]]]],
    ]
}

private final class Recorder {
    private let lock = NSLock()
    private var items: [(String, [String: Any])] = []
    private var shownEvents: [LemuExperienceEvent] = []

    func track(_ name: String, _ props: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        items.append((name, props))
    }

    func emit(_ event: LemuExperienceEvent) {
        lock.lock(); defer { lock.unlock() }
        shownEvents.append(event)
    }

    var tracked: [(String, [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    var names: [String] { return tracked.map { $0.0 } }

    var events: [LemuExperienceEvent] {
        lock.lock(); defer { lock.unlock() }
        return shownEvents
    }
}

private final class FakePresenter: ExperiencePresenter {
    private let lock = NSLock()
    private var shown: [ExperienceViewModel] = []
    var opened: [URL] = []

    func present(_ model: ExperienceViewModel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        shown.append(model)
        return true
    }

    func open(_ url: URL) {
        opened.append(url)
    }

    var models: [ExperienceViewModel] {
        lock.lock(); defer { lock.unlock() }
        return shown
    }
}

private struct Harness {
    let manager: ExperienceManager
    let http: FakeExperienceHTTP
    let presenter: FakePresenter
    let recorder: Recorder
    let store: InMemoryStore
    let clock: MutableClock

    init(bundle: [String: Any], decide: [String: Any]? = nil, submit: [String: Any]? = nil, userId: String? = nil, store: InMemoryStore = InMemoryStore()) {
        http = FakeExperienceHTTP()
        presenter = FakePresenter()
        recorder = Recorder()
        self.store = store
        clock = MutableClock()
        http.responder = { request in
            switch request.path {
            case "/api/v1/pixel/onsite/config": return (200, bundle)
            case "/api/v1/pixel/onsite/decide": return (200, decide ?? ["known": false, "experiences": [String: Any]()])
            case "/api/v1/pixel/onsite/submit": return (200, submit ?? ["ok": true])
            default: return (404, nil)
            }
        }
        let recorder = self.recorder
        let clock = self.clock
        manager = ExperienceManager(ExperienceManager.Dependencies(
            writeKey: "pk_app",
            apiHost: "https://lemu.test/",
            userAgent: "lemu-ios/test",
            http: http,
            store: store,
            now: { clock.now() },
            anonymousId: { "visitor-1" },
            userId: { userId },
            track: { recorder.track($0, $1) },
            presenter: presenter,
            ui: { $0() },
            emit: { recorder.emit($0) }
        ))
    }

    func start() {
        manager.start()
        #expect(waitUntil { http.requests("/api/v1/pixel/onsite/config").count == 1 })
        settle()
    }

    func settle() {
        Thread.sleep(forTimeInterval: 0.05)
        manager.waitForQueue()
    }
}

// MARK: - Rules

@Suite("In-app message rules")
struct ExperienceRuleTests {
    @Test func bucketMatchesTheWebRenderer() {
        #expect(ExperienceRules.hash("") == 2_166_136_261)
        #expect(ExperienceRules.hash("a") == 3_826_002_220)
        #expect(ExperienceRules.hash("abc:1") == 335_668_310)
        #expect(abs(ExperienceRules.bucket("") - 0.5043429000) < 1e-9)
        #expect(abs(ExperienceRules.bucket("a") - 0.8908105597) < 1e-9)
        #expect(abs(ExperienceRules.bucket("abc:1") - 0.0781538687) < 1e-9)
        #expect(abs(ExperienceRules.bucket("visitor-1:42") - 0.3183784358) < 1e-9)
        #expect(abs(ExperienceRules.bucket("3f1c2d4e-0000-4000-8000-000000000001:7") - 0.0275701222) < 1e-9)
    }

    @Test func assignMatchesTheWebRenderer() {
        let ab = experience(["id": 42, "holdout_pct": 10, "variants": [["key": "a", "weight": 50], ["key": "b", "weight": 50]]])
        let expectedAB = ["a", "a", "holdout", "b", "a", "b", "b", "a", "b", "b", "b", "holdout"]
        let split = experience(["id": 7, "holdout_pct": 0, "variants": [["key": "control", "weight": 1], ["key": "new", "weight": 3]]])
        let expectedSplit = ["control", "new", "new", "new", "new", "new", "new", "control", "new", "control", "control", "control"]
        for i in 1 ... 12 {
            var seen = ExperienceSeen()
            #expect(ExperienceRules.assign(ab, visitorId: "visitor-\(i)", seen: &seen) == expectedAB[i - 1], "visitor-\(i)")
            #expect(seen.variant == expectedAB[i - 1])
            var seen2 = ExperienceSeen()
            #expect(ExperienceRules.assign(split, visitorId: "visitor-\(i)", seen: &seen2) == expectedSplit[i - 1], "visitor-\(i)")
        }
    }

    @Test func assignmentIsSticky() {
        let exp = experience(["holdout_pct": 0, "variants": [["key": "a", "weight": 50], ["key": "b", "weight": 50]]])
        var seen = ExperienceSeen()
        seen.variant = "b"
        #expect(ExperienceRules.assign(exp, visitorId: "visitor-1", seen: &seen) == "b")
        seen.variant = "gone" // a variant no longer live is reassigned
        #expect(ExperienceRules.assign(exp, visitorId: "visitor-1", seen: &seen) == "a")
        seen.variant = "holdout" // holdout ended
        #expect(ExperienceRules.assign(exp, visitorId: "visitor-1", seen: &seen) == "a")
    }

    @Test func compareFollowsTheSharedRules() {
        #expect(ExperienceRules.compare("Returning", "eq", "returning"))
        #expect(ExperienceRules.compare(" new ", nil, "NEW"))
        #expect(ExperienceRules.compare("a", "neq", "b"))
        #expect(ExperienceRules.compare(3, "gte", "3"))
        #expect(ExperienceRules.compare(5, "gt", 4.5))
        #expect(!ExperienceRules.compare("x", "gt", 1))
        #expect(ExperienceRules.compare(2, "lt", 3) && ExperienceRules.compare(3, "lte", 3))
        #expect(ExperienceRules.compare("b", "in", ["a", "B"]))
        #expect(ExperienceRules.compare("b", "in", "a, b"))
        #expect(ExperienceRules.compare("c", "not_in", ["a", "b"]))
        #expect(ExperienceRules.compare("Hello World", "contains", "world"))
        #expect(ExperienceRules.compare(nil, "not_contains", "x"))
        #expect(ExperienceRules.compare("x", "exists", nil) && !ExperienceRules.compare("", "exists", nil))
        #expect(ExperienceRules.compare(nil, "not_exists", nil))
        #expect(ExperienceRules.compare(true, "eq", "yes"))
        #expect(ExperienceRules.compare(false, "eq", false))
        #expect(!ExperienceRules.compare(true, "eq", false))
    }

    @Test func eventNamesMatchLoosely() {
        #expect(ExperienceRules.sameEvent("AddToCart", "add_to_cart"))
        #expect(ExperienceRules.sameEvent("Add to cart", "addtocart"))
        #expect(!ExperienceRules.sameEvent("", ""))
        #expect(!ExperienceRules.sameEvent("Purchase", "AddToCart"))
    }

    @Test func whereMatchesScreens() {
        let home = experience(["where": ["include": [["type": "screen_equals", "value": "Home"]]]])
        #expect(ExperienceRules.whereMatches(home, screen: "home"))
        #expect(!ExperienceRules.whereMatches(home, screen: "HomeDetail"))
        let products = experience(["where": ["include": [["type": "screen_prefix", "value": "Product"]], "exclude": [["type": "screen_equals", "value": "ProductReviews"]]]])
        #expect(ExperienceRules.whereMatches(products, screen: "ProductDetail"))
        #expect(!ExperienceRules.whereMatches(products, screen: "productreviews"))
        #expect(!ExperienceRules.whereMatches(products, screen: "Cart"))
        let anywhere = experience(["where": [String: Any]()])
        #expect(ExperienceRules.whereMatches(anywhere, screen: ""))
        let web = experience(["where": ["include": [["type": "path_prefix", "value": "/"]]]])
        #expect(!ExperienceRules.whereMatches(web, screen: "Home"))
    }

    @Test func whoMatchesAppConditions() {
        let returning = experience(["who": ["match": "all", "conditions": [["kind": "visitor", "op": "eq", "value": "returning"]], "server": false]])
        #expect(!ExperienceRules.whoMatches(returning, decision: nil, userId: nil, visits: 1))
        #expect(ExperienceRules.whoMatches(returning, decision: nil, userId: nil, visits: 2))
        let loyal = experience(["who": ["match": "all", "conditions": [["kind": "visit_count", "op": "gte", "value": 3], ["kind": "identified"]], "server": false]])
        #expect(!ExperienceRules.whoMatches(loyal, decision: nil, userId: "u1", visits: 2))
        #expect(!ExperienceRules.whoMatches(loyal, decision: nil, userId: nil, visits: 3))
        #expect(ExperienceRules.whoMatches(loyal, decision: nil, userId: "u1", visits: 3))
        // Browser-only rules are left out in apps.
        let device = experience(["who": ["match": "all", "conditions": [["kind": "device", "op": "eq", "value": "desktop"]], "server": false]])
        #expect(ExperienceRules.whoMatches(device, decision: nil, userId: nil, visits: 1))
        let any = experience(["who": ["match": "any", "conditions": [["kind": "identified"], ["kind": "visit_count", "op": "gt", "value": 5]], "server": false]])
        #expect(!ExperienceRules.whoMatches(any, decision: nil, userId: nil, visits: 1))
        #expect(ExperienceRules.whoMatches(any, decision: nil, userId: "u1", visits: 1))
    }

    @Test func whoMatchesServerAnswers() {
        let server = experience(["who": ["match": "all", "conditions": [Any](), "server": true, "server_conditions": 1]])
        #expect(!ExperienceRules.whoMatches(server, decision: nil, userId: nil, visits: 1))
        let yes = ExperienceDecision(known: true, answers: ["welcome": .init(match: true, hidden: false)])
        let no = ExperienceDecision(known: true, answers: ["welcome": .init(match: false, hidden: false)])
        let hidden = ExperienceDecision(known: true, answers: ["welcome": .init(match: true, hidden: true)])
        #expect(ExperienceRules.whoMatches(server, decision: yes, userId: nil, visits: 1))
        #expect(!ExperienceRules.whoMatches(server, decision: no, userId: nil, visits: 1))
        #expect(!ExperienceRules.whoMatches(server, decision: hidden, userId: nil, visits: 1))
        let anyServer = experience(["who": ["match": "any", "conditions": [["kind": "identified"]], "server": true, "server_conditions": 1]])
        #expect(ExperienceRules.whoMatches(anyServer, decision: yes, userId: nil, visits: 1))
        #expect(!ExperienceRules.whoMatches(anyServer, decision: no, userId: nil, visits: 1))
    }

    @Test func frequencyFollowsTheSharedRules() {
        let now: Int64 = 1_800_000_000_000
        let hour: Int64 = 3_600_000
        var seen = ExperienceSeen()
        let session = experience(["frequency": ["show": "session"]])
        #expect(ExperienceRules.frequencyAllows(session, seen: seen, session: "s1", now: now))
        seen.sessionShown = "s1"
        seen.n = 1
        seen.last = now - hour
        #expect(!ExperienceRules.frequencyAllows(session, seen: seen, session: "s1", now: now))
        #expect(ExperienceRules.frequencyAllows(session, seen: seen, session: "s2", now: now))

        #expect(!ExperienceRules.frequencyAllows(experience(["frequency": ["show": "ever"]]), seen: seen, session: "s2", now: now))
        #expect(ExperienceRules.frequencyAllows(experience(["frequency": ["show": "always"]]), seen: seen, session: "s1", now: now))
        let day = experience(["frequency": ["show": "day"]])
        #expect(!ExperienceRules.frequencyAllows(day, seen: seen, session: "s2", now: now))
        #expect(ExperienceRules.frequencyAllows(day, seen: seen, session: "s2", now: now + 24 * hour))
        let days = experience(["frequency": ["show": "days", "days": 3]])
        #expect(!ExperienceRules.frequencyAllows(days, seen: seen, session: "s2", now: now + 48 * hour))
        #expect(ExperienceRules.frequencyAllows(days, seen: seen, session: "s2", now: now + 72 * hour))

        var submitted = ExperienceSeen()
        submitted.submitted = now
        #expect(!ExperienceRules.frequencyAllows(experience(["frequency": ["show": "always"]]), seen: submitted, session: "s", now: now))
        #expect(ExperienceRules.frequencyAllows(experience(["frequency": ["show": "always", "stop_after_submit": false]]), seen: submitted, session: "s", now: now))

        var closed = ExperienceSeen()
        closed.closes = 1
        closed.lastClose = now - hour
        let always = experience(["frequency": ["show": "always"]])
        #expect(!ExperienceRules.frequencyAllows(always, seen: closed, session: "s", now: now)) // 24 h cooldown
        #expect(ExperienceRules.frequencyAllows(always, seen: closed, session: "s", now: now + 24 * hour))
        #expect(ExperienceRules.frequencyAllows(experience(["frequency": ["show": "always", "cooldown_hours_after_close": 0]]), seen: closed, session: "s", now: now))
        closed.closes = 2
        #expect(!ExperienceRules.frequencyAllows(experience(["frequency": ["show": "always", "max_closes": 2, "cooldown_hours_after_close": 0]]), seen: closed, session: "s", now: now))
    }

    @Test func scheduleWindows() throws {
        // 2026-11-16 is a Monday. 10:00 UTC is 15:30 in Asia/Kolkata.
        let monday = try #require(ISO8601.date(from: "2026-11-16T10:00:00.000Z"))
        #expect(ExperienceRules.scheduleOpen([:], now: monday))
        #expect(!ExperienceRules.scheduleOpen(["start": "2026-11-17T00:00:00Z"], now: monday))
        #expect(!ExperienceRules.scheduleOpen(["end": "2026-11-16T09:00:00Z"], now: monday))
        #expect(ExperienceRules.scheduleOpen(["start": "2026-11-16T09:00:00Z", "end": "2026-11-17T00:00:00Z"], now: monday))
        #expect(ExperienceRules.scheduleOpen(["days_of_week": [0, 1]], now: monday))
        #expect(!ExperienceRules.scheduleOpen(["days_of_week": [5, 6]], now: monday))
        #expect(ExperienceRules.scheduleOpen(["hours": ["from": "15:00", "to": "16:00"]], now: monday))
        #expect(!ExperienceRules.scheduleOpen(["hours": ["from": "09:00", "to": "15:00"]], now: monday))
        #expect(ExperienceRules.scheduleOpen(["hours": ["from": "09:00", "to": "11:00"], "timezone": "UTC"], now: monday))
        #expect(ExperienceRules.scheduleOpen(["hours": ["from": "22:00", "to": "16:00"]], now: monday)) // overnight
    }

    @Test func textHelpers() {
        #expect(ExperienceRules.plainText("Get **10%** off *today*, see [terms](https://x.co)") == "Get 10% off today, see terms")
        #expect(ExperienceRules.fill("Code {{offer.code}} for {{answers.name}}{{answers.none}}", scopes: ["offer": ["code": "SAVE10"], "answers": ["name": "Asha"]]) == "Code SAVE10 for Asha")
    }

    @Test func colorsAndTheme() {
        #expect(ExperienceColor.parse("#fff") == ExperienceColor(red: 1, green: 1, blue: 1, alpha: 1))
        #expect(ExperienceColor.parse("#ff000080")?.alpha ?? 0 > 0.5)
        #expect(ExperienceColor.parse("rgba(17,24,39,0.55)")?.alpha == 0.55)
        #expect(ExperienceColor.parse("blue") == nil)
        let theme = ExperienceTheme(theme: ["primary_color": "#ff0000", "button_style": "pill"], style: ["background": "#000000"])
        #expect(theme.primary.red == 1 && theme.background.red == 0 && theme.buttonRadius == 999 && theme.radius == 12)
    }
}

// MARK: - Bundle and state

@Suite("In-app message bundle and state")
struct ExperienceBundleTests {
    @Test func notLiveMeansNothing() throws {
        let data = try JSONSerialization.data(withJSONObject: ["live": false])
        let bundle = try #require(ExperienceBundle.parse(data))
        #expect(!bundle.live && bundle.experiences.isEmpty)
        #expect(ExperienceBundle.parse("nope".data(using: .utf8)) == nil)
    }

    @Test func keepsOnlyWhatAppsShow() throws {
        var web = experienceJSON("web_only", format: "popup")
        web["platform"] = "web"
        let json = bundleJSON([
            experienceJSON("pop"), experienceJSON("bar", format: "bar"), experienceJSON("toast", format: "toast"),
            experienceJSON("slide", format: "slide_in"), experienceJSON("inline", format: "inline"), web,
        ], decide: true)
        let bundle = ExperienceBundle.parse(json)
        #expect(bundle.experiences.map { $0.key } == ["pop", "bar", "toast", "slide"])
        #expect(bundle.decide && bundle.version == "abc")
        let pop = bundle.experiences[0]
        #expect(pop.variants.first?.steps.first?.blocks.count == 2)
    }

    @Test func sessionsStartAfterThirtyMinutes() {
        var state = ExperienceVisitorState()
        let minute: Int64 = 60 * 1000
        let started = state.touch(now: 1000)
        #expect(started)
        #expect(state.visits == 1 && state.session.count == 8)
        let session = state.session
        let again = state.touch(now: 1000 + 29 * minute)
        #expect(!again)
        #expect(state.session == session)
        let later = state.touch(now: 1000 + 60 * minute)
        #expect(later)
        #expect(state.visits == 2 && state.session != session)
        let restored = ExperienceVisitorState.decode(state.encoded())
        #expect(restored == state)
        #expect(ExperienceVisitorState.decode("{\"visits\":3,\"seen\":{\"x\":{\"n\":2}}}").seen["x"]?.n == 2)
    }
}

// MARK: - View model

@Suite("In-app message forms")
struct ExperienceViewModelTests {
    private final class Host: ExperienceViewModelHost {
        var closed: [Bool] = []
        var clicks: [String] = []
        var opened: [URL] = []
        var submitted: [[String: Any]] = []
        var sent: [([String: Any], String?)] = []
        var reply = ExperienceSubmitResult(status: 200, json: ["ok": true])

        func viewModel(_ model: ExperienceViewModel, closedByUser byUser: Bool) { closed.append(byUser) }
        func viewModel(_ model: ExperienceViewModel, clicked target: String) { clicks.append(target) }
        func viewModel(_ model: ExperienceViewModel, open url: URL) { opened.append(url) }
        func viewModel(_ model: ExperienceViewModel, submitted fields: [String: Any], offer: [String: Any]?) { submitted.append(fields) }
        func viewModel(_ model: ExperienceViewModel, send fields: [String: Any], otp: String?, phoneCountry: String,
                       completion: @escaping (ExperienceSubmitResult) -> Void)
        {
            sent.append((fields, otp))
            completion(reply)
        }
    }

    private func model(_ exp: Experience = experience()) -> (ExperienceViewModel, Host) {
        let m = ExperienceViewModel(experience: exp, variant: exp.variants[0], theme: ExperienceTheme(theme: [:], style: [:]))
        let host = Host()
        m.host = host
        return (m, host)
    }

    @Test func validatesLikeTheWeb() {
        let (m, host) = model()
        m.submit()
        #expect(m.error == "Please fill in the highlighted fields.")
        #expect(m.invalid == ["email"])
        m.setAnswer("email", "not-an-email")
        m.submit()
        #expect(m.error == "Enter a valid email address.")
        m.setAnswer("email", "asha@brand.in")
        m.setAnswer("phone", "123")
        m.submit()
        #expect(m.error == "Enter a valid phone number.")
        #expect(host.sent.isEmpty)
    }

    @Test func submitsAndShowsTheSuccessStepWithTheOffer() {
        let (m, host) = model()
        host.reply = ExperienceSubmitResult(status: 200, json: ["ok": true, "offer": ["code": "SAVE10", "headline": "10% off"]])
        m.setAnswer("email", "asha@brand.in")
        m.setAnswer("phone", "098765 43210")
        m.submit()
        #expect(host.sent.count == 1)
        #expect(host.sent[0].0["email"] as? String == "asha@brand.in")
        #expect(host.sent[0].0["phone"] as? String == "+919876543210")
        #expect(m.currentStep?.id == "success")
        #expect(m.offerCode == "SAVE10")
        #expect(m.text(m.blocks[0]["text"]) == "Your code is SAVE10")
        #expect(m.blocks.contains { $0["type"] as? String == "offer" })
        #expect(host.submitted.count == 1 && host.closed.isEmpty)
        m.codeCopied()
        #expect(host.clicks == ["copy_code"] && m.copyTitle([:]) == "Copied")
    }

    @Test func phoneNumbers() {
        #expect(ExperienceViewModel.phoneNumber("098765 43210", country: "+91") == "+919876543210")
        #expect(ExperienceViewModel.phoneNumber("+44 7700 900123", country: "+91") == "+447700900123")
        #expect(ExperienceViewModel.phoneNumber("  ", country: "+91") == "")
    }

    @Test func serverErrorsAndVerification() {
        let (m, host) = model()
        m.setAnswer("email", "asha@brand.in")
        host.reply = ExperienceSubmitResult(status: 429, json: ["ok": false])
        m.submit()
        #expect(m.error == "Please try again in a minute.")
        host.reply = ExperienceSubmitResult(status: nil, json: nil)
        m.submit()
        #expect(m.error == "Couldn't send. Check your connection and try again.")
        host.reply = ExperienceSubmitResult(status: 400, json: ["ok": false, "errors": ["_form": "This form is closed"]])
        m.submit()
        #expect(m.error == "This form is closed")
        host.reply = ExperienceSubmitResult(status: 200, json: ["ok": false, "verify": true])
        m.submit()
        #expect(m.otpPending)
        #expect(m.blocks.contains { $0["name"] as? String == ExperienceViewModel.otpField })
        #expect(!m.blocks.contains { $0["name"] as? String == "email" })
        m.submit()
        #expect(m.error == "Please fill in the highlighted fields.")
        m.setAnswer(ExperienceViewModel.otpField, "123456")
        host.reply = ExperienceSubmitResult(status: 200, json: ["ok": true])
        m.submit()
        #expect(host.sent.last?.1 == "123456")
        #expect(m.currentStep?.id == "success")
    }

    @Test func dismissesWhenThereIsNoSuccessStep() {
        let exp = experience(["variants": [["key": "a", "weight": 1, "kind": "blocks", "content": ["steps": [
            ["id": "q", "blocks": [["type": "field", "name": "size", "input": "chips", "options": ["S", ["value": "M", "label": "Medium"]], "required": true],
                                   ["type": "button", "text": "Next", "action": "next_step"]]],
            ["id": "form", "blocks": [["type": "field", "name": "agree", "input": "consent", "required": true],
                                      ["type": "button", "text": "Send"]]],
        ]]]]])
        let (m, host) = model(exp)
        #expect(ExperienceViewModel.options(m.blocks[0]).map { $0.label } == ["S", "Medium"])
        m.tapButton(m.blocks[1])
        #expect(m.stepIndex == 0 && m.invalid == ["size"])
        m.setAnswer("size", "M")
        m.tapButton(m.blocks[1])
        #expect(m.stepIndex == 1)
        m.submit()
        #expect(m.invalid == ["agree"])
        m.setAnswer("agree", true)
        m.submit()
        #expect(host.sent.first?.0["size"] as? String == "M")
        #expect(host.sent.first?.0["agree"] as? Bool == true)
        #expect(host.closed == [false] && m.isClosed)
    }

    @Test func buttonsCloseAndOpenLinks() {
        let (m, host) = model()
        m.tapButton(["type": "button", "action": "url", "url": "https://brand.in/sale"])
        #expect(host.clicks == ["https://brand.in/sale"])
        #expect(host.opened == [URL(string: "https://brand.in/sale")!])
        #expect(host.closed == [false])
        let (m2, host2) = model()
        m2.tapOverlay()
        #expect(host2.closed == [true])
        m2.tapButton(["type": "button", "action": "close"])
        #expect(host2.closed == [true]) // only once
    }
}

// MARK: - Manager

@Suite("In-app message manager", .serialized)
struct ExperienceManagerTests {
    @Test func pageLoadOnAMatchingScreenShowsAndTracks() throws {
        let h = Harness(bundle: bundleJSON([experienceJSON("home_offer", id: 9, include: [["type": "screen_equals", "value": "Home"]])]))
        h.start()
        let config = try #require(h.http.requests("/api/v1/pixel/onsite/config").first)
        #expect(config.query == "k=pk_app")
        #expect(config.headers["user-agent"] == "lemu-ios/test")
        #expect(h.presenter.models.isEmpty) // no screen yet
        h.manager.didScreen("Cart", properties: nil)
        h.settle()
        #expect(h.presenter.models.isEmpty)
        h.manager.didScreen("Home", properties: nil)
        h.settle()
        #expect(h.presenter.models.count == 1)
        let viewed = try #require(h.recorder.tracked.first { $0.0 == "onsite_viewed" })
        #expect(viewed.1["experience"] as? String == "home_offer")
        #expect(viewed.1["experience_id"] as? Int == 9)
        #expect(viewed.1["variant"] as? String == "a")
        #expect(viewed.1["version"] as? Int == 1)
        #expect(viewed.1["format"] as? String == "popup")
        #expect(viewed.1["screen"] as? String == "Home")
        #expect(h.recorder.events.map { $0.type } == [.shown])

        // The user closes it; once per session, so it doesn't come back.
        h.presenter.models[0].close(byUser: true)
        h.settle()
        #expect(h.recorder.names.contains("onsite_closed"))
        #expect(h.recorder.events.last?.type == .closed && h.recorder.events.last?.byUser == true)
        h.manager.didScreen("Home", properties: nil)
        h.settle()
        #expect(h.presenter.models.count == 1)

        let stored = ExperienceVisitorState.decode(h.store.string(forKey: "lemu.experiences"))
        #expect(stored.seen["home_offer"]?.n == 1)
        #expect(stored.seen["home_offer"]?.closes == 1)
        #expect(stored.seen["home_offer"]?.variant == "a")
    }

    @Test func eventTriggerManualShowAndPause() {
        let h = Harness(bundle: bundleJSON([
            experienceJSON("cart_nudge", trigger: ["on": "event", "event": "AddToCart"], frequency: ["show": "always"]),
            experienceJSON("size_alert", id: 2, trigger: ["on": "manual"], frequency: ["show": "always"]),
        ]))
        h.start()
        h.manager.didScreen("Product", properties: nil)
        h.settle()
        #expect(h.presenter.models.isEmpty)
        h.manager.didTrack("add_to_cart", properties: nil)
        h.settle()
        #expect(h.presenter.models.map { $0.experience.key } == ["cart_nudge"])
        // One at a time.
        #expect(!h.manager.show("size_alert"))
        h.manager.hide()
        h.settle()
        #expect(h.recorder.events.last?.type == .closed && h.recorder.events.last?.byUser == false)
        #expect(!h.recorder.names.contains("onsite_closed")) // hide() isn't a user close

        h.manager.setEnabled(false)
        #expect(!h.manager.isEnabled)
        h.manager.didTrack("AddToCart", properties: nil)
        h.settle()
        #expect(h.presenter.models.count == 1)
        // Manual show works while paused.
        #expect(h.manager.show("size_alert"))
        #expect(!h.manager.show("missing"))
        #expect(h.presenter.models.map { $0.experience.key } == ["cart_nudge", "size_alert"])
    }

    @Test func holdoutVisitorsSeeNothing() {
        // visitor-1 rolls 0.3184 for id 42: with a 50% holdout they are held out.
        let h = Harness(bundle: bundleJSON([experienceJSON("held", id: 42, holdout: 50)]))
        h.start()
        h.manager.didScreen("Home", properties: nil)
        h.settle()
        #expect(h.presenter.models.isEmpty)
        #expect(h.recorder.names == ["onsite_held_out"])
        #expect(h.recorder.tracked[0].1["variant"] as? String == "holdout")
        #expect(!h.manager.show("held"))
        #expect(h.recorder.names == ["onsite_held_out"]) // once per session
    }

    @Test func serverTargetingAsksDecide() throws {
        let who: [String: Any] = ["match": "all", "conditions": [Any](), "server": true, "server_conditions": 1]
        let h = Harness(
            bundle: bundleJSON([experienceJSON("vip", include: [["type": "screen_equals", "value": "Product"]], who: who)], decide: true),
            decide: ["known": true, "experiences": ["vip": ["match": true, "hidden": false]]],
            userId: "u1"
        )
        h.start()
        h.manager.didTrack("ViewContent", properties: ["content_ids": ["SKU1", "SKU2"]])
        h.manager.didScreen("Product", properties: ["sku": "SKU9"])
        #expect(waitUntil { h.presenter.models.count == 1 })
        let decide = try #require(h.http.requests("/api/v1/pixel/onsite/decide").first)
        #expect(decide.method == "POST")
        #expect(decide.headers["content-type"] == "application/json")
        #expect(decide.json["writeKey"] as? String == "pk_app")
        #expect(decide.json["anonymousId"] as? String == "visitor-1")
        #expect(decide.json["userId"] as? String == "u1")
        let context = try #require(decide.json["context"] as? [String: Any])
        #expect(context["screen"] as? String == "Product")
        #expect((context["product"] as? [String: Any])?["sku"] as? String == "SKU9")
    }

    @Test func submitSendsTheFormAndRecordsIt() throws {
        var exp = experienceJSON("signup", format: "slide_in")
        exp["variants"] = [["key": "b", "weight": 1, "kind": "blocks", "content": ["steps": [
            ["id": "form", "blocks": [["type": "field", "name": "email", "input": "email", "required": true], ["type": "button", "text": "Join"]]],
            ["id": "success", "blocks": [["type": "offer"]]],
        ]]]]
        let h = Harness(bundle: bundleJSON([exp]), submit: ["ok": true, "offer": ["code": "HELLO5"]])
        h.start()
        h.manager.didScreen("Home", properties: nil)
        h.settle()
        let model = try #require(h.presenter.models.first)
        model.setAnswer("email", "asha@brand.in")
        model.submit()
        #expect(waitUntil { model.currentStep?.id == "success" })
        let submit = try #require(h.http.requests("/api/v1/pixel/onsite/submit").first)
        #expect(submit.json["experience"] as? String == "signup")
        #expect(submit.json["variant"] as? String == "b")
        #expect((submit.json["fields"] as? [String: Any])?["email"] as? String == "asha@brand.in")
        let context = try #require(submit.json["context"] as? [String: Any])
        #expect(context["platform"] as? String == "ios" && context["screen"] as? String == "Home")
        #expect(submit.json["otp"] == nil)
        let submitted = try #require(h.recorder.events.first { $0.type == .submitted })
        #expect(submitted.offerCode == "HELLO5")
        #expect(submitted.fields["email"] as? String == "asha@brand.in")
        h.settle()
        #expect(ExperienceVisitorState.decode(h.store.string(forKey: "lemu.experiences")).seen["signup"]?.submitted ?? 0 > 0)
    }

    @Test func showBeforeTheConfigArrivesWaitsForIt() {
        let h = Harness(bundle: bundleJSON([experienceJSON("promo", trigger: ["on": "manual"])]))
        #expect(!h.manager.show("promo"))
        h.start()
        #expect(waitUntil { h.presenter.models.count == 1 })
    }

    @Test func popupCapsPerScreen() {
        let home: [[String: Any]] = [["type": "screen_equals", "value": "Home"]]
        let h = Harness(bundle: bundleJSON([
            experienceJSON("first", include: home, frequency: ["show": "always"]),
            experienceJSON("second", id: 2, trigger: ["on": "event", "event": "anything"], include: home, frequency: ["show": "always"]),
        ]))
        h.start()
        h.manager.didScreen("Home", properties: nil)
        h.settle()
        #expect(h.presenter.models.map { $0.experience.key } == ["first"])
        h.presenter.models[0].close(byUser: false)
        h.settle()
        h.manager.didTrack("anything", properties: nil)
        h.settle()
        #expect(h.presenter.models.count == 1) // popups_per_page is 1
    }
}

// MARK: - Facade

/// In the "Public API" suite: the `Lemu` facade is a singleton those tests also set up and tear down.
extension PublicAPITests {
    @Test func optionsAndSelectors() {
        #expect(LemuOptions().inAppMessages)
        #expect(!LemuOptions(inAppMessages: false).inAppMessages)
        for name in ["show:", "hide", "setEnabled:", "isEnabled", "refresh", "delegate", "setDelegate:"] {
            #expect(LemuExperiences.instancesRespond(to: NSSelectorFromString(name)), "missing -[LemuExperiences \(name)]")
        }
        #expect(Lemu.responds(to: NSSelectorFromString("experiences")))
    }

    @Test func setupLoadsTheConfigUnlessTurnedOff() {
        Lemu.tearDownForTesting()
        defer { Lemu.tearDownForTesting() }
        #expect(!Lemu.experiences.show("x")) // before setup
        let env = TestEnv()
        defer { env.cleanup() }
        env.experienceHTTP.responder = { _ in (200, ["live": false]) }
        Lemu.setup(writeKey: "pk_test_123", options: LemuOptions(flushInterval: 0, trackLifecycle: false), environment: env.environment())
        #expect(waitUntil { env.experienceHTTP.requests("/api/v1/pixel/onsite/config").count == 1 })
        #expect(Lemu.experiences.isEnabled)
        Lemu.experiences.setEnabled(false)
        #expect(!Lemu.experiences.isEnabled)

        Lemu.tearDownForTesting()
        let off = TestEnv()
        defer { off.cleanup() }
        Lemu.setup(writeKey: "pk_test_123", options: LemuOptions(flushInterval: 0, trackLifecycle: false, inAppMessages: false), environment: off.environment())
        Thread.sleep(forTimeInterval: 0.2)
        #expect(off.experienceHTTP.requests.isEmpty)
        #expect(!Lemu.experiences.show("x"))
        #expect(!Lemu.experiences.isEnabled)
    }

    @Test func historyStaysInMemoryUntilConsent() {
        let store = InMemoryStore()
        let blocked = ExperienceManager(ExperienceManager.Dependencies(
            writeKey: "pk", apiHost: "https://lemu.test", userAgent: "ua", http: FakeExperienceHTTP(), store: store,
            storageAllowed: { false }, presenter: nil
        ))
        blocked.start()
        blocked.waitForQueue()
        #expect(store.string(forKey: "lemu.experiences") == nil)
    }
}
