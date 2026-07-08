// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sendling",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sendling",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SendlingTests",
            dependencies: ["Sendling"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
