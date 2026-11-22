import Foundation

/*
 * The experiences bundle (GET /api/v1/pixel/onsite/config), as built by the
 * server's `build_bundle`. Content stays as loose JSON dictionaries: blocks
 * carry many optional keys and the SDK reads only the ones it renders.
 */

typealias JSONObject = [String: Any]

/// Formats an app can render natively. Others in the bundle are skipped.
let appExperienceFormats: Set<String> = ["popup", "slide_in", "toast", "bar"]

/// Formats counted by the popup caps (`popups_per_session`, `popups_per_page`).
let overlayExperienceFormats: Set<String> = ["popup", "slide_in"]

struct ExperienceRule: Equatable {
    var type: String
    var value: String

    init(_ json: Any?) {
        let o = json as? JSONObject ?? [:]
        type = jsonString(o["type"]) ?? "any"
        value = jsonString(o["value"]) ?? ""
    }

    init(type: String, value: String = "") {
        self.type = type
        self.value = value
    }
}

struct ExperienceCondition {
    var kind: String
    var op: String?
    var value: Any?

    init(_ json: Any?) {
        let o = json as? JSONObject ?? [:]
        kind = jsonString(o["kind"]) ?? ""
        op = jsonString(o["op"])
        value = o["value"] is NSNull ? nil : o["value"]
    }

    init(kind: String, op: String? = nil, value: Any? = nil) {
        self.kind = kind
        self.op = op
        self.value = value
    }
}

struct ExperienceVariant {
    var key: String
    var weight: Double
    var kind: String
    var content: JSONObject

    init(_ json: Any?) {
        let o = json as? JSONObject ?? [:]
        key = jsonString(o["key"]) ?? ""
        weight = jsonNumber(o["weight"]) ?? 0
        kind = jsonString(o["kind"]) ?? "blocks"
        content = o["content"] as? JSONObject ?? [:]
    }

    init(key: String, weight: Double, kind: String = "blocks", content: JSONObject = [:]) {
        self.key = key
        self.weight = weight
        self.kind = kind
        self.content = content
    }

    var steps: [ExperienceStep] {
        return (content["steps"] as? [Any] ?? []).map { ExperienceStep($0) }
    }

    var layout: JSONObject {
        return content["layout"] as? JSONObject ?? [:]
    }

    var style: JSONObject {
        return content["style"] as? JSONObject ?? [:]
    }
}

struct ExperienceStep {
    var id: String
    var blocks: [JSONObject]

    init(_ json: Any?) {
        let o = json as? JSONObject ?? [:]
        id = jsonString(o["id"]) ?? ""
        blocks = (o["blocks"] as? [Any] ?? []).compactMap { $0 as? JSONObject }
    }

    var hasFields: Bool {
        return blocks.contains { jsonString($0["type"]) == "field" }
    }
}

struct Experience {
    var id: Int
    var key: String
    var format: String
    var platform: String
    var version: Int
    var schedule: JSONObject
    var include: [ExperienceRule]
    var exclude: [ExperienceRule]
    var whoMatch: String
    var conditions: [ExperienceCondition]
    var serverConditions: Int
    var needsServer: Bool
    var trigger: String
    var triggerSeconds: Double
    var triggerEvent: String?
    var frequency: JSONObject
    var holdoutPct: Double
    var variants: [ExperienceVariant]

    init(_ json: JSONObject) {
        id = Int(jsonNumber(json["id"]) ?? 0)
        key = jsonString(json["key"]) ?? ""
        format = jsonString(json["format"]) ?? ""
        platform = jsonString(json["platform"]) ?? "any"
        version = Int(jsonNumber(json["version"]) ?? 1)
        schedule = json["schedule"] as? JSONObject ?? [:]
        let whereRules = json["where"] as? JSONObject ?? [:]
        include = (whereRules["include"] as? [Any] ?? []).map { ExperienceRule($0) }
        exclude = (whereRules["exclude"] as? [Any] ?? []).map { ExperienceRule($0) }
        let who = json["who"] as? JSONObject ?? [:]
        whoMatch = jsonString(who["match"]) ?? "all"
        conditions = (who["conditions"] as? [Any] ?? []).map { ExperienceCondition($0) }
        serverConditions = Int(jsonNumber(who["server_conditions"]) ?? 0)
        needsServer = (who["server"] as? Bool) ?? false
        let t = json["trigger"] as? JSONObject ?? [:]
        trigger = jsonString(t["on"]) ?? "page_load"
        triggerSeconds = jsonNumber(t["seconds"]) ?? 0
        triggerEvent = jsonString(t["event"])
        frequency = json["frequency"] as? JSONObject ?? ["show": "session"]
        holdoutPct = jsonNumber(json["holdout_pct"]) ?? 0
        variants = (json["variants"] as? [Any] ?? []).map { ExperienceVariant($0) }
    }

    /// Something the app SDK can show: an app or any-platform experience in a
    /// native format, with at least one variant.
    var renderable: Bool {
        return platform != "web" && appExperienceFormats.contains(format) && !variants.isEmpty && !key.isEmpty
    }

    /// `event` triggers, plus `add_to_cart` (the `AddToCart` event).
    var triggerEventName: String? {
        if trigger == "add_to_cart" { return "AddToCart" }
        if trigger == "event" { return triggerEvent }
        return nil
    }
}

struct ExperienceBundle {
    var live: Bool
    var version: String
    var theme: JSONObject
    var caps: JSONObject
    var decide: Bool
    var experiences: [Experience]

    static let empty = ExperienceBundle(live: false, version: "", theme: [:], caps: [:], decide: false, experiences: [])

    init(live: Bool, version: String, theme: JSONObject, caps: JSONObject, decide: Bool, experiences: [Experience]) {
        self.live = live
        self.version = version
        self.theme = theme
        self.caps = caps
        self.decide = decide
        self.experiences = experiences
    }

    /// Parses the config response. `{"live": false}` and anything unreadable
    /// give an empty bundle. Only experiences the app can render are kept.
    static func parse(_ data: Data?) -> ExperienceBundle? {
        guard let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
        else { return nil }
        return parse(json)
    }

    static func parse(_ json: JSONObject) -> ExperienceBundle {
        guard (json["live"] as? Bool) == true else { return .empty }
        let experiences = (json["experiences"] as? [Any] ?? [])
            .compactMap { $0 as? JSONObject }
            .map { Experience($0) }
            .filter { $0.renderable }
        return ExperienceBundle(
            live: true,
            version: jsonString(json["v"]) ?? "",
            theme: json["theme"] as? JSONObject ?? [:],
            caps: json["caps"] as? JSONObject ?? [:],
            decide: (json["decide"] as? Bool) ?? false,
            experiences: experiences
        )
    }
}

/// The server's answer to `/pixel/onsite/decide`.
struct ExperienceDecision {
    struct Answer {
        var match: Bool?
        var hidden: Bool
    }

    var known: Bool
    var answers: [String: Answer]

    static func parse(_ data: Data?) -> ExperienceDecision? {
        guard let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let experiences = json["experiences"] as? JSONObject
        else { return nil }
        var answers: [String: Answer] = [:]
        for (key, value) in experiences {
            let o = value as? JSONObject ?? [:]
            answers[key] = Answer(match: o["match"] as? Bool, hidden: (o["hidden"] as? Bool) ?? false)
        }
        return ExperienceDecision(known: (json["known"] as? Bool) ?? false, answers: answers)
    }
}

// MARK: - Loose JSON readers

func jsonString(_ value: Any?) -> String? {
    switch value {
    case let s as String: return s
    case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.stringValue
    default: return nil
    }
}

func jsonNumber(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.doubleValue
    case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
}

func jsonBool(_ value: Any?) -> Bool? {
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
    return value as? Bool
}
