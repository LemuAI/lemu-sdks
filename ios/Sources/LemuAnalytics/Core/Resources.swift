import Foundation

enum LemuResources {
    /// The bundled privacy manifest. CocoaPods puts it in the
    /// `LemuAnalyticsPrivacy` resource bundle; SwiftPM in `Bundle.module`.
    static var privacyManifestURL: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        #else
        let bundle = Bundle(for: Lemu.self)
        if let url = bundle.url(forResource: "LemuAnalyticsPrivacy", withExtension: "bundle"),
           let resources = Bundle(url: url) {
            return resources.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        }
        return bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        #endif
    }
}
