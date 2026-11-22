import Foundation

/// Which experiences may show, for whom, and which variant. A port of the web
/// renderer's rules (sdks/js/packages/onsite/src/rules.ts and util.ts) so a
/// visitor gets the same answers in the app as on the website.
enum ExperienceRules {
    // MARK: Comparing values

    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let s as String: return ["true", "1", "yes", "y"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        case let n as NSNumber: return n.doubleValue != 0
        case let b as Bool: return b
        default: return true
        }
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        if value is Bool { return true }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return true }
        return false
    }

    /// JavaScript's `String(value)` for the values a bundle holds.
    static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return value == nil ? "undefined" : "null"
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let i as Int64: return String(i)
        case let d as Double:
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case let a as [Any]: return a.map { text($0) }.joined(separator: ",")
        default: return String(describing: value!)
        }
    }

    private static func toNumber(_ value: Any?) -> Double {
        switch value {
        case nil: return .nan
        case is NSNull: return 0
        case let n as NSNumber: return n.doubleValue
        case let b as Bool: return b ? 1 : 0
        case let i as Int: return Double(i)
        case let i as Int64: return Double(i)
        case let d as Double: return d
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return 0 }
            return Double(t) ?? .nan
        default: return .nan
        }
    }

    /// Same rules as util.ts `compare` (and the server's decide.py).
    static func compare(_ actual: Any?, _ op: String?, _ expected: Any?) -> Bool {
        let op = (op?.isEmpty == false ? op! : "eq")
        if op == "exists" {
            guard let actual = actual, !(actual is NSNull) else { return false }
            if let s = actual as? String, s.isEmpty { return false }
            if let a = actual as? [Any], a.isEmpty { return false }
            return true
        }
        if op == "not_exists" { return !compare(actual, "exists", expected) }
        if op == "in" || op == "not_in" {
            let list: [String] = (expected as? [Any])?.map { text($0) } ?? text(expected).components(separatedBy: ",")
            let a = text(actual).trimmingCharacters(in: .whitespaces).lowercased()
            let found = list.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == a }
            return op == "in" ? found : !found
        }
        if op == "contains" || op == "not_contains" {
            let haystack = (actual == nil || actual is NSNull ? "" : text(actual)).lowercased()
            let needle = text(expected).lowercased()
            let found = needle.isEmpty || haystack.contains(needle)
            return op == "contains" ? found : !found
        }
        if ["gt", "gte", "lt", "lte"].contains(op) {
            let a = toNumber(actual)
            let b = toNumber(expected)
            if a.isNaN || b.isNaN { return false }
            switch op {
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            default: return a <= b
            }
        }
        let equal: Bool
        if isBoolean(expected) || isBoolean(actual) {
            equal = truthy(actual) == truthy(expected)
        } else {
            equal = text(actual).trimmingCharacters(in: .whitespaces).lowercased()
                == text(expected).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return op == "neq" ? !equal : equal
    }

    /// Event names match ignoring case, spaces, `_` and `-` ("add to cart" = "AddToCart").
    static func sameEvent(_ configured: String?, _ incoming: String?) -> Bool {
        func norm(_ s: String?) -> String {
            return (s ?? "").lowercased().filter { $0 != " " && $0 != "_" && $0 != "-" && !$0.isWhitespace }
        }
        let a = norm(configured)
        return !a.isEmpty && a == norm(incoming)
    }

    // MARK: Where (screens)

    static func ruleMatches(_ rule: ExperienceRule, screen: String) -> Bool {
        let s = screen.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let v = rule.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rule.type {
        case "any": return true
        case "screen_equals": return s == v
        case "screen_prefix": return s.hasPrefix(v)
        default: return false
        }
    }

    static func whereMatches(_ exp: Experience, screen: String) -> Bool {
        let include = exp.include.isEmpty ? [ExperienceRule(type: "any")] : exp.include
        guard include.contains(where: { ruleMatches($0, screen: screen) }) else { return false }
        return !exp.exclude.contains(where: { ruleMatches($0, screen: screen) })
    }

    // MARK: Who (targeting)

    /// The conditions an app can answer; nil for the others (browser-only
    /// rules such as device, UTM and cart), which are left out.
    static func appCondition(_ c: ExperienceCondition, visits: Int64, userId: String?) -> Bool? {
        switch c.kind {
        case "visitor": return compare(visits > 1 ? "returning" : "new", c.op, c.value)
        case "visit_count": return compare(NSNumber(value: visits), c.op, c.value)
        case "identified": return compare(userId != nil, c.op, c.value ?? true)
        default: return nil
        }
    }

    static func whoMatches(_ exp: Experience, decision: ExperienceDecision?, userId: String?, visits: Int64) -> Bool {
        let results = exp.conditions.compactMap { appCondition($0, visits: visits, userId: userId) }
        let server = decision?.answers[exp.key]
        if exp.needsServer && server == nil { return false }
        if let server = server, server.hidden { return false }
        let serverCount = exp.serverConditions
        if exp.whoMatch == "any" {
            if results.isEmpty && serverCount == 0 { return true }
            return results.contains(true) || (serverCount > 0 && server?.match == true)
        }
        return !results.contains(false) && (serverCount == 0 || server == nil || server?.match != false)
    }

    // MARK: Schedule

    static func parseDate(_ value: Any?) -> Date? {
        guard let s = jsonString(value), !s.isEmpty else { return nil }
        if let d = ISO8601.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // A date and time without a zone, read as UTC.
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        p.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            p.dateFormat = format
            if let d = p.date(from: s) { return d }
        }
        return nil
    }

    static func scheduleOpen(_ schedule: JSONObject, now: Date) -> Bool {
        if let start = parseDate(schedule["start"]), now < start { return false }
        if let end = parseDate(schedule["end"]), now >= end { return false }
        let zone = TimeZone(identifier: jsonString(schedule["timezone"]) ?? "Asia/Kolkata") ?? TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let day = ((parts.weekday ?? 1) + 5) % 7 // Calendar: 1 = Sunday; rules: 0 = Monday
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if let days = schedule["days_of_week"] as? [Any], !days.isEmpty {
            if !days.contains(where: { jsonNumber($0).map { Int($0) } == day }) { return false }
        }
        if let hours = schedule["hours"] as? JSONObject, let from = jsonString(hours["from"]), let to = jsonString(hours["to"]),
           !from.isEmpty, !to.isEmpty
        {
            func toMinutes(_ t: String) -> Int {
                let p = t.split(separator: ":")
                return (Int(p.first ?? "0") ?? 0) * 60 + (p.count > 1 ? Int(p[1]) ?? 0 : 0)
            }
            let f = toMinutes(from)
            let t = toMinutes(to)
            if f <= t ? (minutes < f || minutes >= t) : (minutes < f && minutes >= t) { return false }
        }
        return true
    }

    // MARK: How often

    static func frequencyAllows(_ exp: Experience, seen h: ExperienceSeen, session: String, now: Int64) -> Bool {
        let f = exp.frequency
        if jsonBool(f["stop_after_submit"]) != false && h.submitted > 0 { return false }
        if let maxCloses = jsonNumber(f["max_closes"]), maxCloses > 0, Double(h.closes) >= maxCloses { return false }
        let cooldownHours = jsonNumber(f["cooldown_hours_after_close"]) ?? 24
        let cooldown = Int64(cooldownHours * 3600 * 1000)
        if h.lastClose > 0 && cooldown > 0 && now - h.lastClose < cooldown { return false }
        let day: Int64 = 24 * 3600 * 1000
        switch jsonString(f["show"]) ?? "session" {
        case "always": return true
        case "session": return h.sessionShown != session
        case "day": return h.last == 0 || now - h.last > day
        case "days":
            let days = jsonNumber(f["days"]).flatMap { $0 > 0 ? $0 : nil } ?? 7
            return h.last == 0 || now - h.last > Int64(days) * day
        case "ever": return h.n == 0
        default: return true
        }
    }

    // MARK: Variants

    /// FNV-1a over UTF-16 code units: a stable 0...1 bucket for (visitor, experience).
    static func hash(_ text: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for unit in text.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x0100_0193
        }
        return h
    }

    static func bucket(_ text: String) -> Double {
        return Double(hash(text)) / Double(0xFFFF_FFFF as UInt32)
    }

    /// The sticky variant (or "holdout") for this visitor. Updates `seen.variant`.
    static func assign(_ exp: Experience, visitorId: String, seen h: inout ExperienceSeen) -> String {
        let active = exp.variants.map { $0.key }
        if let v = h.variant, !v.isEmpty, v == "holdout" ? exp.holdoutPct > 0 : active.contains(v) { return v }
        let roll = bucket(visitorId + ":" + String(exp.id))
        var chosen: String
        if roll * 100 < exp.holdoutPct {
            chosen = "holdout"
        } else {
            let divisor = (100 - exp.holdoutPct) == 0 ? 1 : (100 - exp.holdoutPct)
            let rest = (roll * 100 - exp.holdoutPct) / divisor
            var total = exp.variants.reduce(0.0) { $0 + max(0, $1.weight) }
            if total == 0 { total = 1 }
            var acc = 0.0
            chosen = exp.variants.last?.key ?? ""
            for v in exp.variants {
                acc += max(0, v.weight) / total
                if rest < acc {
                    chosen = v.key
                    break
                }
            }
        }
        h.variant = chosen
        return chosen
    }

    // MARK: Text

    private static let placeholder = try! NSRegularExpression(pattern: "\\{\\{\\s*([a-z_]+)\\.([a-z_0-9]+)\\s*\\}\\}", options: [.caseInsensitive])
    private static let link = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
    private static let strong = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static let em = try! NSRegularExpression(pattern: "(^|[^*])\\*([^*]+)\\*(?!\\*)")

    /// `{{answers.size}}`, `{{offer.code}}`: values from the scopes, empty when missing.
    static func fill(_ template: String, scopes: [String: JSONObject]) -> String {
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for m in placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let scope = ns.substring(with: m.range(at: 1))
            let key = ns.substring(with: m.range(at: 2))
            if let v = scopes[scope]?[key], !(v is NSNull) { out += text(v) }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Text blocks as plain text: `**bold**` and `*italic*` markers dropped, `[label](url)` becomes the label.
    static func plainText(_ text: String) -> String {
        var s = text
        s = link.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        s = strong.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        s = em.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1$2")
        return s
    }
}
