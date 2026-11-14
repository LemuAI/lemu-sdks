import Foundation
import Testing
@testable import LemuAnalytics

@Suite("Behaviour")
struct BehaviourTests {
    @Test func contextHasDeviceAppAndNoAdvertisingIds() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()
        client.track("X", properties: nil)
        #expect(flushAndWait(client))

        let message = try #require(env.transport.allMessages.first)
        let context = try #require(message["context"] as? [String: Any])
        let app = try #require(context["app"] as? [String: Any])
        #expect(app["name"] as? String == "Brand")
        #expect(app["version"] as? String == "3.2.0")
        #expect(app["build"] as? String == "320")
        #expect(app["namespace"] as? String == "com.brand.app")
        let device = try #require(context["device"] as? [String: Any])
        #expect(device["manufacturer"] as? String == "Apple")
        #expect(device["model"] as? String == "iPhone15,2")
        #expect(device["type"] as? String == "phone")
        let os = try #require(context["os"] as? [String: Any])
        #expect(os["name"] as? String == "iOS")
        #expect(os["version"] as? String == "17.2")
        let screen = try #require(context["screen"] as? [String: Any])
        #expect(screen["width"] as? Double == 1179)
        #expect(screen["density"] as? Double == 3)
        #expect(context["locale"] is String)
        #expect(context["timezone"] as? String == TimeZone.current.identifier)
        #expect(context["userAgent"] as? String == "lemu-ios/\(LemuVersion.current) (iOS 17.2; iPhone15,2)")
        for key in ["advertisingId", "idfa", "idfv", "gaid"] {
            #expect(context[key] == nil)
            #expect(device[key] == nil)
        }
    }

    @Test func realDeviceInfoIsSensible() {
        let device = DeviceInfo.current()
        #expect(device.manufacturer == "Apple")
        #expect(!device.model.isEmpty)
        #expect(["phone", "tablet", "desktop", "tv", "other"].contains(device.type))
        #expect(!device.osVersion.isEmpty)
        let agent = LemuContextBuilder.userAgent(device: device)
        #expect(agent.hasPrefix("lemu-ios/\(LemuVersion.current) ("))
    }

    @Test func sourcesDoNotUseAdvertisingOrVendorIds() throws {
        let files = FileManager.default.enumerator(at: RepoPaths.iosSources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for banned in ["import AdSupport", "import AppTrackingTransparency", "advertisingIdentifier", "identifierForVendor"] {
                #expect(!source.contains(banned), "\(file.lastPathComponent) uses \(banned)")
            }
        }
    }

    @Test func purchaseFillsContentIdsAndNumItemsFromContents() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.purchase(
            value: 2998, currency: "inr", orderId: "1043",
            contents: [LemuContent(id: "SKU1", quantity: 2, itemPrice: 999, title: "Shirt"), .init(id: "SKU2", quantity: 1)],
            contentIds: nil, numItems: nil,
            properties: ["payment_method": "cod", "value": 1]
        )
        #expect(waitUntil { env.transport.requests.count == 1 })

        let properties = try #require(env.transport.allMessages.first?["properties"] as? [String: Any])
        #expect(properties["value"] as? Double == 2998) // typed argument wins over properties
        #expect(properties["currency"] as? String == "INR")
        #expect(properties["order_id"] as? String == "1043")
        #expect(properties["content_ids"] as? [String] == ["SKU1", "SKU2"])
        #expect(properties["num_items"] as? Int == 3)
        #expect(properties["payment_method"] as? String == "cod")
        let contents = try #require(properties["contents"] as? [[String: Any]])
        #expect(contents.first?["id"] as? String == "SKU1")
        #expect(contents.first?["quantity"] as? Int == 2)
        #expect(contents.first?["item_price"] as? Double == 999)
        #expect(contents.first?["title"] as? String == "Shirt")
        #expect(contents.last?["item_price"] == nil)
    }

    @Test func trackNamedPurchaseAlsoFlushesAtOnce() {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()
        client.track(LemuEvent.purchase, properties: ["value": 10, "currency": "INR", "order_id": "9"])
        #expect(waitUntil { env.transport.requests.count == 1 })
    }

    @Test func flushTimerSendsWithoutFlushCall() {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.flushInterval = 0.2 }
        client.track("X", properties: nil)
        #expect(waitUntil(timeout: 3) { env.transport.requests.count == 1 })
    }

    @Test func deepLinkSetsCampaignForThisAndLaterMessages() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()

        client.track("Before", properties: nil)
        let url = URL(string: "brand://product/42?utm_source=google&utm_medium=cpc&utm_campaign=diwali&fbclid=abc&other=1")!
        client.trackDeepLink(url, referrer: "com.apple.mobilesafari")
        client.track("After", properties: nil)
        #expect(flushAndWait(client))

        let messages = env.transport.allMessages
        #expect(messages.map { $0["event"] as? String } == ["Before", "deep_link_opened", "After"])
        let before = try #require(messages[0]["context"] as? [String: Any])
        #expect(before["campaign"] == nil)
        let link = try #require(messages[1]["properties"] as? [String: Any])
        #expect(link["url"] as? String == url.absoluteString)
        #expect(link["referrer"] as? String == "com.apple.mobilesafari")
        for message in messages.dropFirst() {
            let campaign = try #require((message["context"] as? [String: Any])?["campaign"] as? [String: Any])
            #expect(campaign["source"] as? String == "google")
            #expect(campaign["medium"] as? String == "cpc")
            #expect(campaign["campaign"] as? String == "diwali")
            #expect(campaign["fbclid"] as? String == "abc")
            #expect(campaign["other"] == nil)
        }
    }

    @Test func deepLinkEventCanBeTurnedOff() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.trackDeepLinks = false }
        client.trackDeepLink(URL(string: "brand://x?utm_source=meta")!, referrer: nil)
        client.track("After", properties: nil)
        #expect(flushAndWait(client))
        let messages = env.transport.allMessages
        #expect(messages.map { $0["event"] as? String } == ["After"])
        let campaign = (messages.first?["context"] as? [String: Any])?["campaign"] as? [String: Any]
        #expect(campaign?["source"] as? String == "meta")
    }

    @Test func appOpenedCarriesTheLinkThatOpenedTheApp() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.trackDeepLinks = false }
        client.trackDeepLink(URL(string: "brand://sale")!, referrer: nil)
        client.trackApplicationOpened(fromBackground: true)
        client.trackApplicationOpened(fromBackground: true)
        client.trackApplicationBackgrounded()
        #expect(flushAndWait(client))
        let messages = env.transport.allMessages
        #expect(messages.map { $0["event"] as? String } == ["app_opened", "app_opened", "app_backgrounded"])
        let first = try #require(messages[0]["properties"] as? [String: Any])
        #expect(first["url"] as? String == "brand://sale")
        #expect(first["from_background"] as? Bool == true)
        #expect((messages[1]["properties"] as? [String: Any])?["url"] == nil)
    }

    @Test func retriesStopTwentyHoursAfterTheFirstAttempt() {
        let env = TestEnv()
        defer { env.cleanup() }
        let offline = FakeTransport()
        offline.defaultResult = .status(503)
        let client = env.makeClient(transport: offline) { $0.retryBaseDelay = 600 }

        client.track("X", properties: nil)
        #expect(flushAndWait(client))
        #expect(client.queuedCount == 1)

        env.clock.advance(19 * 3600)
        #expect(flushAndWait(client))
        #expect(client.queuedCount == 1)

        env.clock.advance(1 * 3600 + 1)
        #expect(flushAndWait(client))
        #expect(client.queuedCount == 0)
        #expect(offline.requests.count == 3)
    }

    @Test func messagesOlderThanSevenDaysAreDroppedBeforeSending() {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()
        client.track("Old", properties: nil)
        client.waitForQueue()
        env.clock.advance(7 * 24 * 3600 + 60)
        client.track("New", properties: nil)
        #expect(flushAndWait(client))
        #expect(env.transport.allMessages.compactMap { $0["event"] as? String } == ["New"])
    }

    @Test func rateLimitIsRetried() {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueue(429, 204)
        let client = env.makeClient()
        client.track("X", properties: nil)
        client.flush()
        #expect(waitUntil { env.transport.requests.count == 2 && client.queuedCount == 0 })
    }

    @Test func networkFailureIsRetried() {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueueFailure()
        let client = env.makeClient()
        client.track("X", properties: nil)
        client.flush()
        #expect(waitUntil { env.transport.requests.count == 2 && client.queuedCount == 0 })
    }

    @Test func backoffDoublesWithJitterAndCapsAtFiveMinutes() {
        for attempt in 1 ... 5 {
            let expected = pow(2, Double(attempt - 1))
            for _ in 0 ..< 50 {
                let delay = LemuClient.backoff(attempt: attempt, base: 1, cap: 300)
                #expect(delay >= expected * 0.8 && delay <= expected * 1.2)
            }
        }
        for _ in 0 ..< 50 {
            let delay = LemuClient.backoff(attempt: 30, base: 1, cap: 300)
            #expect(delay >= 240 && delay <= 360)
        }
    }

    @Test func oversizedBatchIsSplitBeforeSending() {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.maxRequestBytes = 6000 }
        let padding = String(repeating: "x", count: 1500)
        for index in 0 ..< 8 { client.track("E\(index)", properties: ["pad": padding]) }
        #expect(flushAndWait(client))
        let requests = env.transport.requests
        #expect(requests.allSatisfy { $0.body.count <= 6000 })
        #expect(requests.flatMap { $0.messages }.count == 8)
        #expect(requests.count > 1)
    }

    @Test func identifyUserIdIsRememberedAcrossInstances() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let first = env.makeClient()
        first.identify(userId: "u9", traits: nil)
        let anonymousId = first.anonymousId
        first.shutdown()

        let second = env.makeClient()
        #expect(second.currentUserId == "u9")
        #expect(second.anonymousId == anonymousId)
        second.track("X", properties: nil)
        #expect(flushAndWait(second))
        #expect(env.transport.allMessages.last?["userId"] as? String == "u9")
    }

    @Test func consentWithoutRequireConsentCanBeRefused() {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()
        client.setConsent(false)
        client.track("X", properties: nil)
        #expect(flushAndWait(client))
        settle(client, seconds: 0.1)
        #expect(env.transport.requests.isEmpty)

        let next = env.makeClient()
        next.track("Y", properties: nil)
        #expect(flushAndWait(next))
        #expect(env.transport.requests.isEmpty)
    }

    @Test func consentIsRememberedOnceGranted() {
        let env = TestEnv()
        defer { env.cleanup() }
        let first = env.makeClient { $0.requireConsent = true }
        first.setConsent(true)
        first.waitForQueue()
        first.shutdown()

        let second = env.makeClient { $0.requireConsent = true }
        second.track("X", properties: nil)
        #expect(flushAndWait(second))
        #expect(env.transport.allMessages.count == 1)
    }

    @Test func heldMessagesAreCappedAtFifty() {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.requireConsent = true }
        for index in 0 ..< 60 { client.track("E\(index)", properties: nil) }
        client.waitForQueue()
        #expect(client.heldCount == 50)
        client.setConsent(true)
        #expect(waitUntil { env.transport.allMessages.count == 50 })
        #expect(env.transport.allMessages.first?["event"] as? String == "E10")
    }

    @Test func lifecycleBeforeConsentWritesNothing() {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient { $0.requireConsent = true }
        client.trackApplicationLaunch(app: env.app)
        client.identify(userId: "u1", traits: nil)
        client.waitForQueue()
        #expect(env.store.isEmpty)
        client.setConsent(true)
        client.waitForQueue()
        #expect(env.store.string(forKey: StoreKey.appVersion) == "3.2.0")
        #expect(env.store.string(forKey: StoreKey.userId) == "u1")
        #expect(waitUntil { env.transport.allMessages.count == 2 })
    }

    @Test func corruptQueueLinesAreSkipped() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let first = env.makeClient { $0.retryBaseDelay = 600 }
        first.track("A", properties: nil)
        first.track("B", properties: nil)
        first.shutdown()
        first.waitForQueue()

        let file = env.directory.appendingPathComponent(PersistentQueue.fileName(writeKey: "pk_test_123"))
        var data = try Data(contentsOf: file)
        data.append(Data("{\"id\":\"broken".utf8)) // a write cut short
        try data.write(to: file)

        let second = env.makeClient()
        #expect(second.queuedCount == 2)
        second.track("C", properties: nil)
        #expect(flushAndWait(second))
        #expect(env.transport.allMessages.compactMap { $0["event"] as? String } == ["A", "B", "C"])
    }

    @Test func queueDirectoryIsExcludedFromBackup() throws {
        let env = TestEnv()
        defer { env.cleanup() }
        let client = env.makeClient()
        client.track("X", properties: nil)
        client.waitForQueue()
        let values = try env.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(PersistentQueue.defaultDirectory().path.hasSuffix("Application Support/Lemu"))
    }

    @Test func debugLogsCallsRequestsAndResponses() {
        let env = TestEnv()
        defer { env.cleanup() }
        env.transport.enqueue(401)
        let client = env.makeClient { $0.debug = true }
        client.track("X", properties: nil)
        #expect(flushAndWait(client))
        let logs = env.logs.joined(separator: "\n")
        #expect(logs.contains("track X"))
        #expect(logs.contains("POST "))
        #expect(logs.contains("response 401"))
    }

    @Test func userDefaultsStoreRoundTrip() {
        let suite = "com.lemuai.analytics.tests.\(UUID().uuidString)"
        let store = UserDefaultsStore(suiteName: suite)
        store.set("abc", forKey: StoreKey.anonymousId)
        #expect(store.string(forKey: StoreKey.anonymousId) == "abc")
        store.set(nil, forKey: StoreKey.anonymousId)
        #expect(store.string(forKey: StoreKey.anonymousId) == nil)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @Test func jsonValueConversion() {
        let value = JSONValue.properties([
            "int": 3, "double": 2.5, "bool": true, "nsBool": NSNumber(value: false),
            "nsInt": NSNumber(value: 7), "decimal": Decimal(string: "1499.5")!,
            "array": [1, "a"], "dict": ["k": "v"], "uuid": UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
        ])
        #expect(value["int"] == .int(3))
        #expect(value["double"] == .double(2.5))
        #expect(value["bool"] == .bool(true))
        #expect(value["nsBool"] == .bool(false))
        #expect(value["nsInt"] == .int(7))
        #expect(value["decimal"] == .double(1499.5))
        #expect(value["array"] == .array([.int(1), .string("a")]))
        #expect(value["dict"] == .object(["k": .string("v")]))
        #expect(value["uuid"] == .string("6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    }

    @Test func endpointIgnoresTrailingSlash() {
        var config = LemuConfiguration(writeKey: "k")
        config.apiHost = "https://collect.brand.com/"
        #expect(config.endpoint.absoluteString == "https://collect.brand.com/api/v1/pixel/batch")
        let defaults = LemuConfiguration(writeKey: "k", options: LemuOptions())
        #expect(defaults.endpoint.absoluteString == "https://app.lemuai.com/api/v1/pixel/batch")
        #expect(defaults.flushAt == 20)
        #expect(defaults.flushInterval == 30)
        #expect(defaults.maxQueueSize == 1000)
    }
}
