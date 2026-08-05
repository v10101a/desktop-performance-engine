// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopPerformanceEngine",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DesktopPerformanceEngine",
            path: "Sources/DesktopPerformanceEngine",
            resources: [
                .copy("Resources/timeline.json")
            ]
        )
    ]
)
