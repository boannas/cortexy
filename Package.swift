// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cortexy",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Cortexy", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The `cortexy` command and MCP server, put in Cortexy.app/Contents/Helpers by build.sh.
        .executableTarget(name: "cortexy-cli", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CortexyTests", dependencies: ["Cortexy", "cortexy-cli"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
