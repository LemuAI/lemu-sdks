// swift-tools-version:5.7
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
            path: "Sources/LemuAnalytics",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "LemuAnalyticsTests",
            dependencies: ["LemuAnalytics"],
            path: "Tests/LemuAnalyticsTests"
        ),
    ]
)
