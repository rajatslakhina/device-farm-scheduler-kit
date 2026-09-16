// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "device-farm-scheduler-kit",
    // Only platforms CI actually builds are declared. The Linux job builds the
    // whole package; the macOS job builds it for iOS Simulator via the demo app.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DeviceFarmScheduler", targets: ["DeviceFarmScheduler"]),
        .library(name: "DeviceFarmSchedulerUI", targets: ["DeviceFarmSchedulerUI"]),
    ],
    targets: [
        .target(
            name: "DeviceFarmScheduler",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeviceFarmSchedulerUI",
            dependencies: ["DeviceFarmScheduler"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeviceFarmSchedulerTests",
            dependencies: ["DeviceFarmScheduler"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
