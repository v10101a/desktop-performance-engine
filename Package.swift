// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopPerformanceEngine",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything except the process entry point. Split out of the executable so it
        // can be `@testable import`ed — an executable target with top-level code in
        // main.swift can't be imported by a test target.
        .target(
            name: "DPECore",
            path: "Sources/DPECore",
            resources: [
                .copy("Resources/timeline.json")
            ]
        ),
        .executableTarget(
            name: "DesktopPerformanceEngine",
            dependencies: ["DPECore"],
            path: "Sources/DesktopPerformanceEngine"
        ),
        // Not a .testTarget: this toolchain is Command Line Tools only, which ships
        // neither XCTest nor swift-testing, so `swift test` cannot run. A plain
        // executable gives real assertions and a real exit code without either.
        .executableTarget(
            name: "dpe-tests",
            dependencies: ["DPECore"],
            path: "Sources/DPETests"
        ),
    ]
)
