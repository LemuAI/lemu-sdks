// swift-tools-version:5.7
// Swift Package Manager reads Package.swift at the repository root, so this
// file lets apps add https://github.com/LemuAI/lemu-sdks as a package. It
// builds the same sources as ios/Package.swift (where the tests live).
import PackageDescription

let package = Package(
    name: "LemuAnalytics",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "LemuAnalytics", targets: ["LemuAnalytics"]),
    ],
    targets: [
        .target(
            name: "LemuAnalytics",
            path: "ios/Sources/LemuAnalytics",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
    ]
)
