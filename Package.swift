// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Launcher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LauncherCore"),
        .executableTarget(name: "Launcher", dependencies: ["LauncherCore"]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"]),
    ]
)
