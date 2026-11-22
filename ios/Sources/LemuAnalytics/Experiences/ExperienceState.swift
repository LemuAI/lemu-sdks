import Foundation

/// One experience's history on this device.
struct ExperienceSeen: Codable, Equatable {
    var n: Int64 = 0 // times shown
    var last: Int64 = 0
    var closes: Int64 = 0
    var lastClose: Int64 = 0
    var submitted: Int64 = 0
    var variant: String?
    var sessionShown: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = (try? c.decodeIfPresent(Int64.self, forKey: .n)) ?? 0
        last = (try? c.decodeIfPresent(Int64.self, forKey: .last)) ?? 0
        closes = (try? c.decodeIfPresent(Int64.self, forKey: .closes)) ?? 0
        lastClose = (try? c.decodeIfPresent(Int64.self, forKey: .lastClose)) ?? 0
        submitted = (try? c.decodeIfPresent(Int64.self, forKey: .submitted)) ?? 0
        variant = try? c.decodeIfPresent(String.self, forKey: .variant)
        sessionShown = try? c.decodeIfPresent(String.self, forKey: .sessionShown)
    }
}

/// What the SDK remembers about this device's visits and the experiences it
/// has shown (stored as JSON under `lemu.experiences`). Frequency caps are checked against it.
struct ExperienceVisitorState: Codable, Equatable {
    static let storeKey = "lemu.experiences"
    static let sessionGapMillis: Int64 = 30 * 60 * 1000

    var visits: Int64 = 0
    var first: Int64 = 0
    var last: Int64 = 0
    var session = ""
    var sessionStart: Int64 = 0
    var popupsThisSession: Int64 = 0
    var seen: [String: ExperienceSeen] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visits = (try? c.decodeIfPresent(Int64.self, forKey: .visits)) ?? 0
        first = (try? c.decodeIfPresent(Int64.self, forKey: .first)) ?? 0
        last = (try? c.decodeIfPresent(Int64.self, forKey: .last)) ?? 0
        session = (try? c.decodeIfPresent(String.self, forKey: .session)) ?? ""
        sessionStart = (try? c.decodeIfPresent(Int64.self, forKey: .sessionStart)) ?? 0
        popupsThisSession = (try? c.decodeIfPresent(Int64.self, forKey: .popupsThisSession)) ?? 0
        seen = (try? c.decodeIfPresent([String: ExperienceSeen].self, forKey: .seen)) ?? [:]
    }

    static func decode(_ text: String?) -> ExperienceVisitorState {
        guard let data = text?.data(using: .utf8),
              let state = try? JSONDecoder().decode(ExperienceVisitorState.self, from: data)
        else { return ExperienceVisitorState() }
        return state
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Starts a new session when there is none or the last activity was more
    /// than 30 minutes ago. Returns true when a new session began.
    @discardableResult
    mutating func touch(now: Int64) -> Bool {
        let fresh = session.isEmpty || now - last > ExperienceVisitorState.sessionGapMillis
        if fresh {
            visits += 1
            session = ExperienceVisitorState.newSessionId()
            sessionStart = now
            popupsThisSession = 0
        }
        if first == 0 { first = now }
        last = now
        return fresh
    }

    func seenFor(_ key: String) -> ExperienceSeen {
        return seen[key] ?? ExperienceSeen()
    }

    static func newSessionId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< 8).map { _ in chars[Int.random(in: 0 ..< chars.count)] })
    }
}
