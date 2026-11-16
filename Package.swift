// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "G5Editor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "G5Core", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "g5tool", dependencies: ["G5Core"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "G5Editor", dependencies: ["G5Core"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
