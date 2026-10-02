// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cortexy",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Cortexy", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CortexyTests", dependencies: ["Cortexy"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
