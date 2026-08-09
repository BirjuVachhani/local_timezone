// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// One package for both Apple platforms. The plugin is a single source file
// serving iOS and macOS, declared with `sharedDarwinSource: true` in the
// pubspec, so there is one manifest here rather than two near-identical ones.
let package = Package(
    name: "flutter_local_timezone",
    platforms: [
        .iOS("13.0"),
        .macOS("10.15")
    ],
    products: [
        .library(name: "flutter-local-timezone", targets: ["flutter_local_timezone"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_local_timezone",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            // SwiftPM treats anything in a target's source directory that it
            // does not recognise as source as unhandled, and quietly leaves it
            // out of the build. Without this line the privacy manifest sits
            // beside the plugin and reaches no app: a debug build of test_host
            // contained only the engine's own copy inside
            // FlutterMacOS.framework. Apple expects a manifest from each third
            // party SDK in a submitted app, and ours only travels if it is
            // built into a resource bundle here.
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
