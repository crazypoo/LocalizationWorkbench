// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalizationWorkbench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalizationCore", targets: ["LocalizationCore"]),
        .executable(name: "LocalizationWorkbenchApp", targets: ["LocalizationWorkbenchApp"]),
        .executable(name: "localization-workbench", targets: ["LocalizationWorkbenchCLI"])
    ],
    targets: [
        .target(name: "LocalizationCore"),
        .executableTarget(name: "LocalizationWorkbenchApp", dependencies: ["LocalizationCore"]),
        .executableTarget(name: "LocalizationWorkbenchCLI", dependencies: ["LocalizationCore"]),
        .testTarget(name: "LocalizationCoreTests", dependencies: ["LocalizationCore"])
    ]
)
