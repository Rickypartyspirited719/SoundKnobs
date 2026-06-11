// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoundKnobs",
    platforms: [
        .macOS("14.4") // Core Audio process taps require 14.4+
    ],
    targets: [
        .executableTarget(
            name: "SoundKnobs",
            path: "Sources/SoundKnobs"
        )
    ]
)
