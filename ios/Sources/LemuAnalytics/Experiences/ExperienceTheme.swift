import Foundation

/// A colour as 0...1 components.
struct ExperienceColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)` and `rgba(r, g, b, a)`. Nil for anything else.
    static func parse(_ value: Any?) -> ExperienceColor? {
        guard var s = jsonString(value)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if s.hasPrefix("#") {
            s.removeFirst()
            if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
            guard s.count == 6 || s.count == 8, let n = UInt64(s, radix: 16) else { return nil }
            let has = s.count == 8
            let r = Double((n >> (has ? 24 : 16)) & 0xFF) / 255
            let g = Double((n >> (has ? 16 : 8)) & 0xFF) / 255
            let b = Double((n >> (has ? 8 : 0)) & 0xFF) / 255
            let a = has ? Double(n & 0xFF) / 255 : 1
            return ExperienceColor(red: r, green: g, blue: b, alpha: a)
        }
        if s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let parts = s[s.index(after: open) ..< close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let rgb = parts.prefix(3).compactMap { Double($0) }
            guard rgb.count == 3 else { return nil }
            let a = parts.count == 4 ? (Double(parts[3]) ?? 1) : 1
            return ExperienceColor(
                red: min(255, max(0, rgb[0])) / 255,
                green: min(255, max(0, rgb[1])) / 255,
                blue: min(255, max(0, rgb[2])) / 255,
                alpha: min(1, max(0, a))
            )
        }
        return nil
    }
}

/// The bundle's theme with the variant's style overrides, as the web renderer reads them (styles.ts).
struct ExperienceTheme: Equatable {
    var primary: ExperienceColor
    var text: ExperienceColor
    var background: ExperienceColor
    var muted: ExperienceColor
    var buttonText: ExperienceColor
    var overlay: ExperienceColor
    var radius: Double
    var buttonRadius: Double

    init(theme: JSONObject, style: JSONObject) {
        func pick(_ keys: [(JSONObject, String)], _ fallback: String) -> ExperienceColor {
            for (dict, key) in keys {
                if let c = ExperienceColor.parse(dict[key]) { return c }
            }
            return ExperienceColor.parse(fallback)!
        }
        primary = pick([(style, "primary_color"), (theme, "primary_color")], "#111827")
        text = pick([(style, "text_color"), (theme, "text_color")], "#111827")
        background = pick([(style, "background"), (style, "background_color"), (theme, "background_color")], "#ffffff")
        muted = pick([(style, "muted_color"), (theme, "muted_color")], "#6b7280")
        buttonText = pick([(style, "button_text_color"), (theme, "button_text_color")], "#ffffff")
        overlay = pick([(style, "overlay_color"), (theme, "overlay_color")], "rgba(17,24,39,0.55)")
        radius = jsonNumber(style["radius"]) ?? jsonNumber(theme["radius"]) ?? 12
        if jsonString(theme["button_style"]) == "pill" {
            buttonRadius = 999
        } else {
            buttonRadius = jsonNumber(theme["button_radius"]) ?? 8
        }
    }
}
