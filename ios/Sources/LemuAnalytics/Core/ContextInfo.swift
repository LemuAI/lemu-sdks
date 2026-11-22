import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The app the SDK runs in.
struct AppInfo: Equatable {
    var name: String?
    var version: String?
    var build: String?
    var namespace: String?

    static func current(bundle: Bundle = .main) -> AppInfo {
        let info = bundle.infoDictionary ?? [:]
        return AppInfo(
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String),
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            namespace: bundle.bundleIdentifier
        )
    }

    var json: JSONValue {
        var app: [String: JSONValue] = [:]
        if let name = name { app["name"] = .string(name) }
        if let version = version { app["version"] = .string(version) }
        if let build = build { app["build"] = .string(build) }
        if let namespace = namespace { app["namespace"] = .string(namespace) }
        return .object(app)
    }
}

struct ScreenInfo: Equatable {
    var width: Double
    var height: Double
    var density: Double
}

/// The device and OS. No advertising id, no IDFV, no hardware ids.
struct DeviceInfo: Equatable {
    var manufacturer = "Apple"
    var model: String
    var type: String
    var osName: String
    var osVersion: String
    var screen: ScreenInfo?

    static func current() -> DeviceInfo {
        let model = modelIdentifier()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { osVersion += ".\(version.patchVersion)" }
        return DeviceInfo(
            model: model,
            type: deviceType(model: model),
            osName: osName,
            osVersion: osVersion,
            screen: nil
        )
    }

    static var osName: String {
        #if targetEnvironment(macCatalyst)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    /// `iPhone15,2`, `iPad13,4`, `AppleTV14,1`, `Mac14,2`. On the simulator,
    /// the model being simulated.
    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        if let model = sysctlString("hw.model") { return model }
        #endif
        var system = utsname()
        uname(&system)
        var machine = ""
        for child in Mirror(reflecting: system.machine).children {
            guard let byte = child.value as? Int8, byte != 0 else { break }
            machine.append(Character(UnicodeScalar(UInt8(bitPattern: byte))))
        }
        return machine.isEmpty ? "unknown" : machine
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    static func deviceType(model: String) -> String {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return "desktop"
        #elseif os(tvOS)
        return "tv"
        #else
        if model.hasPrefix("iPad") { return "tablet" }
        if model.hasPrefix("iPhone") || model.hasPrefix("iPod") { return "phone" }
        if model.hasPrefix("AppleTV") { return "tv" }
        return "other"
        #endif
    }

    /// Screen size in pixels and the scale factor. UIKit wants the main
    /// thread, so call this from the main thread only.
    static func mainScreen() -> ScreenInfo? {
        #if canImport(UIKit) && (os(iOS) || os(tvOS)) && !targetEnvironment(macCatalyst)
        let screen = UIScreen.main
        let size = screen.nativeBounds.size
        return ScreenInfo(width: Double(size.width), height: Double(size.height), density: Double(screen.nativeScale))
        #else
        return nil
        #endif
    }
}

enum LemuContextBuilder {
    static func userAgent(device: DeviceInfo) -> String {
        return "lemu-ios/\(LemuVersion.current) (\(device.osName) \(device.osVersion); \(device.model))"
    }

    static func locale() -> String {
        if let preferred = Locale.preferredLanguages.first, !preferred.isEmpty { return preferred }
        return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// The parts of `context` that don't change during a session.
    static func base(app: AppInfo, device: DeviceInfo) -> [String: JSONValue] {
        var context: [String: JSONValue] = [
            "platform": .string("ios"),
            "library": .object(["name": .string("lemu-ios"), "version": .string(LemuVersion.current)]),
            "device": .object([
                "manufacturer": .string(device.manufacturer),
                "model": .string(device.model),
                "type": .string(device.type),
            ]),
            "os": .object(["name": .string(device.osName), "version": .string(device.osVersion)]),
            "locale": .string(locale()),
            "timezone": .string(TimeZone.current.identifier),
            "userAgent": .string(userAgent(device: device)),
        ]
        let appJSON = app.json
        if let fields = appJSON.objectValue, !fields.isEmpty { context["app"] = appJSON }
        if let screen = device.screen {
            context["screen"] = .object([
                "width": .double(screen.width),
                "height": .double(screen.height),
                "density": .double(screen.density),
            ])
        }
        return context
    }
}

public enum LemuVersion {
    /// The SDK version, sent in `context.library.version` and the User-Agent.
    public static let current = "1.1.0"
}
