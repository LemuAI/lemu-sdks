import Foundation
import os.log

// MARK: - Clock

/// Source of the current time. Tests inject a clock they can move.
protocol LemuClock {
    func now() -> Date
}

struct SystemClock: LemuClock {
    func now() -> Date { return Date() }
}

// MARK: - Key-value storage

/// Small settings (anonymous id, user id, opt-out, stored app version).
/// Production uses UserDefaults; tests use an in-memory store.
protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults

    init(suiteName: String = "com.lemuai.analytics") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func string(forKey key: String) -> String? {
        return defaults.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class InMemoryStore: KeyValueStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    init() {}

    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty
    }

    var allKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(values.keys)
    }
}

enum StoreKey {
    static let anonymousId = "lemu.anonymousId"
    static let userId = "lemu.userId"
    static let optOut = "lemu.optOut"
    static let consent = "lemu.consent"
    static let appVersion = "lemu.appVersion"
    static let appBuild = "lemu.appBuild"
}

// MARK: - Logging

final class LemuLogger {
    let enabled: Bool
    /// Tests capture lines here.
    var sink: ((String) -> Void)?
    private let log = OSLog(subsystem: "com.lemuai.analytics", category: "Lemu")

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func debug(_ message: @autoclosure () -> String) {
        guard enabled || sink != nil else { return }
        let text = message()
        sink?(text)
        if enabled {
            os_log("%{public}@", log: log, type: .debug, "[Lemu] " + text)
        }
    }

    /// Misuse worth a line even when debug is off (for example calls before setup).
    func warning(_ message: String) {
        sink?(message)
        os_log("%{public}@", log: log, type: .error, "[Lemu] " + message)
    }
}

// MARK: - Transport

enum TransportResult {
    case status(Int)
    case failure(Error)
}

/// Sends one HTTP request. The SDK uses URLSession; tests inject fakes.
protocol LemuTransport {
    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void)
}

final class URLSessionTransport: LemuTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest, completion: @escaping (TransportResult) -> Void) {
        let task = session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                completion(.status(http.statusCode))
            } else {
                completion(.failure(error ?? URLError(.badServerResponse)))
            }
        }
        task.resume()
    }
}
