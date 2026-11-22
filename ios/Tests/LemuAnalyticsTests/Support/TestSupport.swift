import Foundation
@testable import LemuAnalytics

// MARK: - Paths

enum RepoPaths {
    /// `sdks/` (the lemu-sdks repo root), found from this file's path.
    static let sdksRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // LemuAnalyticsTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // sdks

    static let eventsJSON = sdksRoot.appendingPathComponent("spec/events.json")
    static let batchSchema = sdksRoot.appendingPathComponent("conformance/batch.schema.json")
    static let iosSources = sdksRoot.appendingPathComponent("ios/Sources/LemuAnalytics")
}

// MARK: - Clock

final class MutableClock: LemuClock {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_794_650_400)) { // 2026-11-14T10:00:00Z
        current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Recorded requests

struct RecordedRequest {
    let method: String
    let path: String
    let headers: [String: String] // lower-cased names
    let body: Data

    var json: [String: Any] {
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    var messages: [[String: Any]] {
        return json["batch"] as? [[String: Any]] ?? []
    }

    var messageIds: [String] {
        return messages.compactMap { $0["messageId"] as? String }
    }

    func header(_ name: String) -> String? {
        return headers[name.lowercased()]
    }
}

// MARK: - Fake transport

/// Records requests and answers with scripted statuses (204 when the script is empty).
final class FakeTransport: LemuTransport {
    private let lock = NSLock()
    /// A serial queue of its own: swift-testing runs blocking test bodies on
    /// global-queue threads, so answering on DispatchQueue.global() can starve.
    private let callbackQueue = DispatchQueue(label: "lemu.tests.fake-transport")
    private var script: [TransportResult] = []
    private var recorded: [RecordedRequest] = []
    var defaultResult: TransportResult = .status(204)

    func enqueue(_ statuses: Int...) {
        lock.lock(); defer { lock.unlock() }
        script.append(contentsOf: statuses.map { .status($0) })
    }

    func enqueueFailure(count: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        for _ in 0 ..< count { script.append(.failure(URLError(.notConnectedToInternet))) }
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var allMessages: [[String: Any]] {
        return requests.flatMap { $0.messages }
    }

    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let record = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            headers: headers,
            body: request.httpBody ?? Data()
        )
        lock.lock()
        recorded.append(record)
        let result = script.isEmpty ? defaultResult : script.removeFirst()
        lock.unlock()
        callbackQueue.async { completion(result) }
    }
}

// MARK: - Fake HTTP for in-app messages

/// Answers config, decide and submit requests from a responder (404 by default) and records them.
final class FakeExperienceHTTP: ExperienceHTTP {
    struct Request {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let json: [String: Any]
    }

    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "lemu.tests.fake-experience-http")
    private var recorded: [Request] = []
    var responder: (Request) -> (Int?, Any?) = { _ in (404, nil) }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requests(_ path: String) -> [Request] {
        return requests.filter { $0.path == path }
    }

    func send(_ request: URLRequest, completion: @escaping (Int?, Data?) -> Void) {
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let json = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let r = Request(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            query: request.url?.query ?? "",
            headers: headers,
            json: json
        )
        lock.lock()
        recorded.append(r)
        let respond = responder
        lock.unlock()
        let (status, body) = respond(r)
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        callbackQueue.async { completion(status, data) }
    }
}

// MARK: - Test environment

/// A client wired to a fake clock, store, directory and transport.
final class TestEnv {
    let directory: URL
    let store = InMemoryStore()
    let clock = MutableClock()
    let transport = FakeTransport()
    let experienceHTTP = FakeExperienceHTTP()
    var app = AppInfo(name: "Brand", version: "3.2.0", build: "320", namespace: "com.brand.app")
    let device = DeviceInfo(
        model: "iPhone15,2", type: "phone", osName: "iOS", osVersion: "17.2",
        screen: ScreenInfo(width: 1179, height: 2556, density: 3)
    )
    private(set) var clients: [LemuClient] = []
    var logs: [String] = []
    private let logLock = NSLock()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemu-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func environment(transport: LemuTransport? = nil) -> LemuEnvironment {
        return LemuEnvironment(
            clock: clock,
            transport: transport ?? self.transport,
            store: store,
            directory: directory,
            app: app,
            device: device,
            logSink: { [weak self] line in
                guard let self = self else { return }
                self.logLock.lock()
                self.logs.append(line)
                self.logLock.unlock()
            },
            experienceHTTP: experienceHTTP
        )
    }

    func makeClient(
        transport: LemuTransport? = nil,
        _ configure: (inout LemuConfiguration) -> Void = { _ in }
    ) -> LemuClient {
        var config = LemuConfiguration(writeKey: "pk_test_123")
        config.flushInterval = 0 // tests flush explicitly unless they test the timer
        config.flushAt = 1000
        config.retryBaseDelay = 0.05
        config.retryMaxDelay = 0.2
        configure(&config)
        let client = LemuClient(config: config, environment: environment(transport: transport))
        client.waitForQueue()
        clients.append(client)
        return client
    }

    /// Files the SDK wrote in its directory.
    var filesOnDisk: [String] {
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    func cleanup() {
        clients.forEach { $0.shutdown() }
        clients.forEach { $0.waitForQueue() }
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Waiting

@discardableResult
func flushAndWait(_ client: LemuClient, timeout: TimeInterval = 5) -> Bool {
    let done = DispatchSemaphore(value: 0)
    client.flush { done.signal() }
    return done.wait(timeout: .now() + timeout) == .success
}

@discardableResult
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// Lets queued work and in-flight fakes settle, for "nothing happens" checks.
func settle(_ client: LemuClient, seconds: TimeInterval = 0.3) {
    client.waitForQueue()
    Thread.sleep(forTimeInterval: seconds)
    client.waitForQueue()
}

// MARK: - Wire format helpers

private let uuidV4 = try! NSRegularExpression(
    pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
)

func isUUIDv4(_ value: String?) -> Bool {
    guard let value = value else { return false }
    return uuidV4.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

func parseISO(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return ISO8601.date(from: string)
}
