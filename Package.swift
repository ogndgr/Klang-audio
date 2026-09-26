// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Klang",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "KlangCore"),
        .executableTarget(name: "Klang", dependencies: ["KlangCore"]),
        .testTarget(name: "KlangCoreTests", dependencies: ["KlangCore"]),
    ]
)
