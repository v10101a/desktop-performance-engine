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
                .copy("Resources/timeline.json"),
                // hydra-synth (AGPL-3.0) and the page that hosts it. Copied rather
                // than processed: the library must stay byte-identical to the release
                // it claims to be, and the page loads it by name from the same folder.
                .copy("Resources/hydra-synth.js"),
                .copy("Resources/hydra.html")
            ]
        )
    ]
)
