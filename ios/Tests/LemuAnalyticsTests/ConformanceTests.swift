import Foundation
import Testing
@testable import LemuAnalytics

/// Scenarios C01 to C20 from `sdks/conformance/README.md`, each named after its id.
/// Every recorded request body is checked against `conformance/batch.schema.json`.
@Suite("Conformance")
struct ConformanceTests {
    func expectValid(_ requests: [RecordedRequest], sourceLocation: SourceLocation = #_sourceLocation) {
        for request in requests {
            let errors = SchemaValidator.batch.validate(body: request.body)
            #expect(errors.isEmpty, "schema errors: \(errors)", sourceLocation: sourceLocation)
            #expect(request.method == "POST", sourceLocation: sourceLocation)
            #expect(request.path == "/api/v1/pixel/batch", sourceLocation: sourceLocation)
        }
    }

    @Test func C01_trackThenFlushSendsOneValidRequest() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.track("AddToCart", properties: ["value": 999, "currency": "INR"])
        #expect(flushAndWait(client))

        let requests = env.transport.requests
        #expect(requests.count == 1)
        expectValid(requests)
        let request = try #require(requests.first)
        #expect(request.json["writeKey"] as? String == "pk_test_123")
        let message = try #require(request.messages.first)
        #expect(message["type"] as? String == "track")
        #expect(message["event"] as? String == "AddToCart")
        let properties = try #require(message["properties"] as? [String: Any])
        #expect(properties["value"] as? Int == 999)
        #expect(properties["currency"] as? String == "INR")
        let context = try #require(message["context"] as? [String: Any])
        #expect(context["platform"] as? String == "ios")
        let library = try #require(context["library"] as? [String: Any])
        #expect(library["name"] as? String == "lemu-ios")
        #expect(library["version"] as? String == LemuVersion.current)
        #expect(request.header("User-Agent")?.hasPrefix("lemu-") == true)
        #expect(request.header("User-Agent") == "lemu-ios/\(LemuVersion.current) (iOS 17.2; iPhone15,2)")
        #expect(request.header("Content-Type") == "application/json")
    }

    @Test func C01_overRealHTTP() throws {
        let server = try LocalIngestServer()
        defer { server.stop() }
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient(transport: URLSessionTransport(timeout: 5)) { $0.apiHost = server.baseURL }

        client.track("AddToCart", properties: ["value": 999, "currency": "INR"])
        #expect(flushAndWait(client, timeout: 10))

        let requests = server.requests
        #expect(requests.count == 1)
        expectValid(requests)
        let request = try #require(requests.first)
        #expect(request.header("user-agent")?.hasPrefix("lemu-ios/") == true)
        #expect(request.messages.first?["event"] as? String == "AddToCart")
        #expect(client.queuedCount == 0)
    }

    @Test func C02_twoTracksShareAnonymousIdWithDistinctMessageIds() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.track("A", properties: nil)
        client.track("B", properties: nil)
        #expect(flushAndWait(client))

        expectValid(env.transport.requests)
        let messages = env.transport.allMessages
        #expect(messages.count == 2)
        let anonymousIds = Set(messages.compactMap { $0["anonymousId"] as? String })
        #expect(anonymousIds.count == 1)
        #expect(isUUIDv4(anonymousIds.first))
        let messageIds = messages.compactMap { $0["messageId"] as? String }
        #expect(Set(messageIds).count == 2)
        #expect(messageIds.allSatisfy { isUUIDv4($0) })
    }

    @Test func C03_identifyThenTrackCarriesUserId() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.identify(userId: "u1", traits: ["email": "a@b.co"])
        client.track("X", properties: nil)
        #expect(flushAndWait(client))

        expectValid(env.transport.requests)
        let messages = env.transport.allMessages
        #expect(messages.count == 2)
        let identify = try #require(messages.first)
        #expect(identify["type"] as? String == "identify")
        #expect(identify["userId"] as? String == "u1")
        #expect((identify["traits"] as? [String: Any])?["email"] as? String == "a@b.co")
        let track = try #require(messages.last)
        #expect(track["type"] as? String == "track")
        #expect(track["userId"] as? String == "u1")
    }

    @Test func C04_resetGivesNewAnonymousIdAndNoUserId() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.identify(userId: "u1", traits: ["email": "a@b.co"])
        client.track("X", properties: nil)
        client.reset()
        client.track("X", properties: nil)
        #expect(flushAndWait(client))

        expectValid(env.transport.requests)
        let messages = env.transport.allMessages
        #expect(messages.count == 3)
        let before = try #require(messages[1]["anonymousId"] as? String)
        let after = try #require(messages[2]["anonymousId"] as? String)
        #expect(before != after)
        #expect(isUUIDv4(after))
        #expect(messages[2]["userId"] == nil)
        #expect(client.currentUserId == nil)
        #expect(env.store.string(forKey: StoreKey.userId) == nil)
        #expect(env.store.string(forKey: StoreKey.anonymousId) == after)
    }

    @Test func C05_purchaseIsSentWithoutFlush() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.purchase(value: 1499.5, currency: "INR", orderId: "1042", contents: nil, contentIds: nil, numItems: nil, properties: nil)

        #expect(waitUntil { env.transport.requests.count == 1 })
        expectValid(env.transport.requests)
        let message = try #require(env.transport.allMessages.first)
        #expect(message["event"] as? String == "Purchase")
        let properties = try #require(message["properties"] as? [String: Any])
        #expect(properties["value"] as? Double == 1499.5)
        #expect(properties["currency"] as? String == "INR")
        #expect(properties["order_id"] as? String == "1042")
    }

    @Test func C06_twentyTracksSendWithoutFlush() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.flushAt = 20 }

        for index in 0 ..< 19 { client.track("E\(index)", properties: nil) }
        settle(client, seconds: 0.1)
        #expect(env.transport.requests.isEmpty)

        client.track("E19", properties: nil)
        #expect(waitUntil { env.transport.requests.count == 1 })
        expectValid(env.transport.requests)
        #expect(env.transport.requests.first?.messages.count == 20)
    }

    @Test func C07_requireConsentHoldsInMemoryUntilConsent() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.requireConsent = true }

        client.track("X", properties: nil)
        #expect(flushAndWait(client))
        settle(client)
        #expect(env.transport.requests.isEmpty)
        #expect(env.store.isEmpty, "stored before consent: \(env.store.allKeys)")
        #expect(env.filesOnDisk.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.directory.path))
        #expect(client.heldCount == 1)

        client.setConsent(true)
        #expect(waitUntil { env.transport.requests.count == 1 })
        expectValid(env.transport.requests)
        let messages = env.transport.allMessages
        #expect(messages.count == 1)
        #expect(messages.first?["event"] as? String == "X")
        // After consent the anonymous id held in memory is the one stored.
        #expect(env.store.string(forKey: StoreKey.anonymousId) == messages.first?["anonymousId"] as? String)
    }

    @Test func C08_consentRefusedDiscardsHeldMessages() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.requireConsent = true }

        client.track("X", properties: nil)
        client.setConsent(false)
        client.setConsent(true)
        #expect(flushAndWait(client))
        settle(client)
        #expect(env.transport.requests.isEmpty)
        #expect(client.queuedCount == 0)
    }

    @Test func C09_optOutStopsEverythingAndIsRemembered() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let first = env.makeClient()

        first.optOut()
        first.track("X", properties: nil)
        #expect(flushAndWait(first))
        settle(first)
        #expect(env.transport.requests.isEmpty)
        first.shutdown()

        let second = env.makeClient()
        #expect(second.isOptedOut)
        second.track("X", properties: nil)
        #expect(flushAndWait(second))
        settle(second)
        #expect(env.transport.requests.isEmpty)

        second.optIn()
        second.track("Y", properties: nil)
        #expect(flushAndWait(second))
        expectValid(env.transport.requests)
        #expect(env.transport.allMessages.map { $0["event"] as? String } == ["Y"])
    }

    @Test func C10_serverErrorIsRetriedWithSameMessageIds() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueue(500, 204)
        let client = env.makeClient()

        client.track("X", properties: nil)
        client.track("Y", properties: nil)
        client.flush()

        #expect(waitUntil { env.transport.requests.count == 2 })
        #expect(waitUntil { client.queuedCount == 0 })
        settle(client)
        let requests = env.transport.requests
        #expect(requests.count == 2)
        expectValid(requests)
        #expect(requests[0].messageIds == requests[1].messageIds)
        #expect(requests[0].messageIds.count == 2)
    }

    @Test func C10_overRealHTTP() throws {
        let server = try LocalIngestServer()
        defer { server.stop() }
        server.enqueue(500, 204)
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient(transport: URLSessionTransport(timeout: 5)) { $0.apiHost = server.baseURL }

        client.track("X", properties: nil)
        client.flush()

        #expect(waitUntil(timeout: 10) { server.requests.count == 2 && client.queuedCount == 0 })
        let requests = server.requests
        expectValid(requests)
        #expect(requests.count == 2)
        #expect(requests.first?.messageIds == requests.last?.messageIds)
    }

    @Test func C11_badRequestIsDroppedNotRetried() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueue(400)
        let client = env.makeClient()

        client.track("X", properties: nil)
        #expect(flushAndWait(client))
        settle(client, seconds: 0.5) // several retry delays
        #expect(env.transport.requests.count == 1)
        #expect(client.queuedCount == 0)
        expectValid(env.transport.requests)
    }

    @Test(arguments: [401, 403])
    func C11_unauthorizedAndForbiddenAreDropped(status: Int) throws {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueue(status)
        let client = env.makeClient()

        client.track("X", properties: nil)
        #expect(flushAndWait(client))
        settle(client, seconds: 0.4)
        #expect(env.transport.requests.count == 1)
        #expect(client.queuedCount == 0)
    }

    @Test func C12_payloadTooLargeSplitsTheBatch() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueue(413)
        let client = env.makeClient()

        client.track("A", properties: nil)
        client.track("B", properties: nil)
        #expect(flushAndWait(client))
        #expect(waitUntil { env.transport.requests.count == 3 })

        let requests = env.transport.requests
        expectValid(requests)
        #expect(requests.map { $0.messages.count } == [2, 1, 1])
        #expect(requests[1].messageIds + requests[2].messageIds == requests[0].messageIds)
        #expect(client.queuedCount == 0)
    }

    @Test func C12_singleMessageStillTooLargeIsDropped() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueue(413)
        let client = env.makeClient()

        client.track("A", properties: nil)
        #expect(flushAndWait(client))
        settle(client)
        #expect(env.transport.requests.count == 1)
        #expect(client.queuedCount == 0)
    }

    @Test func C13_queueSurvivesANewInstance() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let offline = FakeTransport()
        offline.defaultResult = .failure(URLError(.notConnectedToInternet))
        let first = env.makeClient(transport: offline) { $0.retryBaseDelay = 60 }

        for name in ["A", "B", "C"] { first.track(name, properties: nil) }
        #expect(flushAndWait(first))
        #expect(first.queuedCount == 3)
        first.shutdown()
        first.waitForQueue()

        let second = env.makeClient()
        #expect(second.queuedCount == 3)
        #expect(flushAndWait(second))
        expectValid(env.transport.requests)
        #expect(env.transport.allMessages.compactMap { $0["event"] as? String } == ["A", "B", "C"])
        #expect(Set(env.transport.requests.flatMap { $0.messageIds }) == Set(offline.requests.flatMap { $0.messageIds }))
    }

    @Test func C13_overRealHTTPWithServerDownThenUp() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        // Nothing listens on this port yet: connection refused.
        let down = try LocalIngestServer()
        let deadHost = down.baseURL
        down.stop()

        let first = env.makeClient(transport: URLSessionTransport(timeout: 2)) {
            $0.apiHost = deadHost
            $0.retryBaseDelay = 60
        }
        for name in ["A", "B", "C"] { first.track(name, properties: nil) }
        #expect(flushAndWait(first, timeout: 10))
        #expect(first.queuedCount == 3)
        first.shutdown()

        let server = try LocalIngestServer()
        defer { server.stop() }
        let second = env.makeClient(transport: URLSessionTransport(timeout: 5)) { $0.apiHost = server.baseURL }
        #expect(flushAndWait(second, timeout: 10))
        expectValid(server.requests)
        #expect(server.requests.flatMap { $0.messages }.compactMap { $0["event"] as? String } == ["A", "B", "C"])
    }

    @Test func C14_queueKeepsAThousandAndThePurchase() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let offline = FakeTransport()
        offline.defaultResult = .failure(URLError(.notConnectedToInternet))
        let client = env.makeClient(transport: offline) {
            $0.flushAt = 20
            $0.retryBaseDelay = 600
            $0.retryMaxDelay = 600
        }

        // The Purchase is the oldest message, so dropping strictly oldest-first would lose it.
        client.purchase(value: 10, currency: "INR", orderId: "o-1", contents: nil, contentIds: nil, numItems: nil, properties: nil)
        for index in 0 ..< 1000 { client.track("E\(index)", properties: nil) }
        client.waitForQueue()

        let queued = client.queuedMessages
        #expect(queued.count == 1000)
        #expect(queued.contains { $0.isPurchase })
        #expect(queued.first?.isPurchase == true)
        #expect(!queued.contains { $0.message["event"]?.stringValue == "E0" }) // oldest non-Purchase dropped

        // The limit holds on disk too.
        client.shutdown()
        let reloaded = env.makeClient(transport: offline) { $0.retryBaseDelay = 600 }
        #expect(reloaded.queuedCount == 1000)
    }

    @Test func C15_firstLaunchThenUpdate() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        env.app.version = "1.0"
        env.app.build = "10"
        let first = env.makeClient()
        first.trackApplicationLaunch(app: env.app)
        #expect(flushAndWait(first))
        first.shutdown()

        env.app.version = "1.1"
        env.app.build = "11"
        let second = env.makeClient()
        second.trackApplicationLaunch(app: env.app)
        #expect(flushAndWait(second))
        second.shutdown()

        let third = env.makeClient()
        third.trackApplicationLaunch(app: env.app) // same version: nothing
        #expect(flushAndWait(third))

        expectValid(env.transport.requests)
        let messages = env.transport.allMessages
        #expect(messages.map { $0["event"] as? String } == ["app_installed", "app_updated"])
        let installed = try #require(messages.first?["properties"] as? [String: Any])
        #expect(installed["version"] as? String == "1.0")
        #expect(installed["build"] as? String == "10")
        let updated = try #require(messages.last?["properties"] as? [String: Any])
        #expect(updated["version"] as? String == "1.1")
        #expect(updated["build"] as? String == "11")
        #expect(updated["previous_version"] as? String == "1.0")
        #expect(updated["previous_build"] as? String == "10")
    }

    @Test func C16_screen() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.screen("Checkout", properties: ["step": 2])
        #expect(flushAndWait(client))

        expectValid(env.transport.requests)
        let message = try #require(env.transport.allMessages.first)
        #expect(message["type"] as? String == "screen")
        #expect(message["name"] as? String == "Checkout")
        #expect((message["properties"] as? [String: Any])?["step"] as? Int == 2)
    }

    @Test func C17_invalidArgumentsNeverThrowAndSendNothing() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.track("", properties: ["a": 1])
        client.track("   ", properties: nil)
        client.screen("", properties: nil)
        client.identify(userId: nil, traits: nil)
        client.identify(userId: "", traits: [:])
        client.purchase(value: .nan, currency: "INR", orderId: "1", contents: nil, contentIds: nil, numItems: nil, properties: nil)
        client.trackDeepLink(URL(string: "app://x")!, referrer: nil) // valid: sends deep_link_opened
        let odd: [String: Any] = [
            "nan": Double.nan,
            "inf": Double.infinity,
            "nil": Optional<String>.none as Any,
            "null": NSNull(),
            "date": Date(timeIntervalSince1970: 0),
            "url": URL(string: "https://x.co/a")!,
            "object": NSObject(),
            "nested": ["deep": ["deeper": [1, 2.5, true, "x"]]],
        ]
        client.track("X", properties: odd)
        client.track("Y", properties: nil)
        #expect(flushAndWait(client))

        expectValid(env.transport.requests)
        let events = env.transport.allMessages.compactMap { $0["event"] as? String }
        #expect(events == ["deep_link_opened", "X", "Y"])
        let x = try #require(env.transport.allMessages.first { $0["event"] as? String == "X" })
        let properties = try #require(x["properties"] as? [String: Any])
        #expect(properties["nan"] == nil)
        #expect(properties["inf"] == nil)
        #expect(properties["nil"] is NSNull)
        #expect(properties["date"] as? String == "1970-01-01T00:00:00.000Z")
        #expect(properties["url"] as? String == "https://x.co/a")
        #expect(properties["object"] is String)
        let y = try #require(env.transport.allMessages.first { $0["event"] as? String == "Y" })
        #expect((y["properties"] as? [String: Any])?.isEmpty == true)
    }

    @Test func C18_sentAtIsSetAtSendTime() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.track("X", properties: nil)
        client.waitForQueue()
        env.clock.advance(5)
        client.track("Y", properties: nil)
        client.waitForQueue()
        env.clock.advance(5)
        #expect(flushAndWait(client))

        let request = try #require(env.transport.requests.first)
        expectValid([request])
        let sentAt = try #require(parseISO(request.json["sentAt"]))
        #expect(sentAt == env.clock.now())
        for message in request.messages {
            let timestamp = try #require(parseISO(message["timestamp"]))
            #expect(sentAt >= timestamp)
        }
        #expect(parseISO(request.messages[0]["timestamp"]) == env.clock.now().addingTimeInterval(-10))
    }

    @Test func C19_batchesOfAtMostFifty() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        for index in 0 ..< 120 { client.track("E\(index)", properties: nil) }
        #expect(flushAndWait(client))

        let requests = env.transport.requests
        expectValid(requests)
        #expect(requests.map { $0.messages.count } == [50, 50, 20])
        #expect(Set(requests.flatMap { $0.messageIds }).count == 120)
    }

    @Test func C20_eventNameConstantsMatchEventsJSON() throws {
        let data = try Data(contentsOf: RepoPaths.eventsJSON)
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let meta = try #require(spec["meta_events"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        let lifecycle = try #require(spec["lifecycle_events"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        #expect(meta.count == 18)
        #expect(lifecycle.count == 6)
        #expect(LemuEvent.metaEvents == meta)
        #expect(LemuEvent.lifecycleEvents == lifecycle)

        // Each name has its own constant: PageView -> LemuEvent.pageView, app_installed -> LemuEvent.appInstalled.
        for name in meta + lifecycle {
            let property = LemuEventNames.constantName(for: name)
            let value = (LemuEvent.self as AnyObject).value(forKey: property) as? String
            #expect(value == name, "LemuEvent.\(property) should be \"\(name)\"")
        }
    }
}

enum LemuEventNames {
    static func constantName(for name: String) -> String {
        let parts = name.split(separator: "_").map(String.init)
        let camel = parts.enumerated().map { index, part in
            index == 0 ? part : part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
        return camel.prefix(1).lowercased() + camel.dropFirst()
    }
}
