import Foundation
import Testing
@testable import LemuAnalytics

/// Tests through the `Lemu` facade. It is a process-wide singleton, so these run one at a time.
@Suite("Public API", .serialized)
struct PublicAPITests {
    @Test func callsBeforeSetupAreIgnoredWithoutCrashing() {
        Lemu.tearDownForTesting()
        Lemu.track("X")
        Lemu.screen("Home")
        Lemu.identify(userId: "u1")
        Lemu.purchase(value: 1, currency: "INR", orderId: "1")
        Lemu.trackDeepLink(URL(string: "brand://x")!)
        Lemu.reset()
        Lemu.flush()
        Lemu.setConsent(true)
        Lemu.optOut()
        Lemu.optIn()
        #expect(Lemu.anonymousId == nil)
        #expect(!Lemu.isOptedOut)
        let done = DispatchSemaphore(value: 0)
        Lemu.flush { done.signal() }
        #expect(done.wait(timeout: .now() + 1) == .success)
    }

    @Test func setupTrackPurchaseAndFlushThroughTheFacade() throws {
        Lemu.tearDownForTesting()
        defer { Lemu.tearDownForTesting() }
        let env = TestEnv()
        defer { env.cleanup() }

        let options = LemuOptions(debug: false, flushInterval: 0, trackLifecycle: true)
        Lemu.setup(writeKey: "pk_test_123", options: options, environment: env.environment())
        Lemu.setup(writeKey: "pk_other", options: options, environment: env.environment()) // ignored
        #expect(Lemu.currentClient?.config.writeKey == "pk_test_123")

        let anonymousId = try #require(Lemu.anonymousId)
        #expect(isUUIDv4(anonymousId))

        Lemu.identify(userId: "u1", traits: ["email": "a@b.co", "first_name": "Asha"])
        Lemu.track(LemuEvent.addToCart, properties: ["value": 999, "currency": "INR", "content_ids": ["SKU1"]])
        Lemu.screen("Checkout", properties: ["step": 2])
        Lemu.purchase(value: 1499.5, currency: "INR", orderId: "1042", contents: [.init(id: "SKU1", quantity: 1)])

        #expect(waitUntil { env.transport.allMessages.count == 5 })
        let events = env.transport.allMessages.map { ($0["type"] as? String ?? "") + ":" + ($0["event"] as? String ?? $0["name"] as? String ?? "") }
        #expect(events == ["track:app_installed", "identify:", "track:AddToCart", "screen:Checkout", "track:Purchase"])
        for request in env.transport.requests {
            #expect(SchemaValidator.batch.validate(body: request.body).isEmpty)
        }

        Lemu.reset()
        #expect(Lemu.anonymousId != anonymousId)
        Lemu.optOut()
        #expect(Lemu.isOptedOut)
        Lemu.optIn()
        #expect(!Lemu.isOptedOut)
    }

    @Test func emptyWriteKeyIsIgnored() {
        Lemu.tearDownForTesting()
        defer { Lemu.tearDownForTesting() }
        Lemu.setup(writeKey: "   ", options: LemuOptions(), environment: TestEnv().environment())
        #expect(Lemu.currentClient == nil)
    }

    @Test func objectiveCSelectorsExist() {
        let selectors = [
            "setupWithWriteKey:options:", "track:properties:", "screen:properties:",
            "identifyWithUserId:traits:", "purchaseWithValue:currency:orderId:contents:properties:",
            "trackDeepLink:referrer:", "reset", "flush", "setConsent:", "optOut", "optIn", "anonymousId",
        ]
        for name in selectors {
            #expect(Lemu.responds(to: NSSelectorFromString(name)), "missing +[Lemu \(name)]")
        }
        #expect(LemuContent.instancesRespond(to: NSSelectorFromString("initWithId:quantity:itemPrice:title:")))
        #expect(NSClassFromString("LemuOptions") != nil)
        #expect(NSClassFromString("LemuEvent") != nil)
    }

    @Test func optionsDefaults() {
        let options = LemuOptions()
        #expect(options.apiHost == "https://app.lemuai.com")
        #expect(!options.debug)
        #expect(!options.requireConsent)
        #expect(options.flushAt == 20)
        #expect(options.flushInterval == 30)
        #expect(options.maxQueueSize == 1000)
        #expect(options.trackLifecycle)
        #expect(options.trackDeepLinks)
    }

    #if canImport(SwiftUI)
    @Test func swiftUIModifierBuilds() {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, *) {
            _ = SwiftUIProbe.view()
        }
    }
    #endif
}

@Suite("Privacy manifest")
struct PrivacyManifestTests {
    @Test func privacyManifestIsBundled() throws {
        let url = try #require(LemuResources.privacyManifestURL)
        let data = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)

        let apis = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let defaults = apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" }
        #expect((defaults?["NSPrivacyAccessedAPITypeReasons"] as? [String]) == ["CA92.1"])

        let collected = try #require(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        for expected in [
            "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypePhoneNumber", "NSPrivacyCollectedDataTypeProductInteraction",
            "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeOtherUsageData",
        ] {
            #expect(types.contains(expected), "missing \(expected)")
        }
        #expect(!types.contains("NSPrivacyCollectedDataTypeDeviceID"))
        #expect(!types.contains("NSPrivacyCollectedDataTypeAdvertisingData"))
        for entry in collected {
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect((entry["NSPrivacyCollectedDataTypePurposes"] as? [String])?.isEmpty == false)
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

@available(macOS 10.15, iOS 13.0, tvOS 13.0, *)
enum SwiftUIProbe {
    static func view() -> some View {
        Text("Checkout").lemuScreen("Checkout", properties: ["step": 2])
    }
}
#endif
