// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LapAnalysis",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LapCore", targets: ["LapCore"]),
        .executable(name: "LapAnalysisApp", targets: ["LapAnalysisApp"]),
    ],
    targets: [
        // Platform-neutral core: file parsing, lap maths, device protocol.
        // No AppKit/UIKit/SwiftUI imports allowed here so it can be shared with iOS.
        .target(name: "LapCore"),
        .executableTarget(
            name: "LapAnalysisApp",
            dependencies: ["LapCore"]
        ),
        .testTarget(
            name: "LapCoreTests",
            dependencies: ["LapCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
