// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetMon",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "NetMon",
            path: "Sources/NetMon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NetMonTests",
            dependencies: ["NetMon"],
            path: "Tests/NetMonTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
