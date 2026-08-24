// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GiveIt2Me_DJ_Dave_malware",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything except the process entry point. Split out of the executable so it
        // can be `@testable import`ed — an executable target with top-level code in
        // main.swift can't be imported by a test target.
        .target(
            name: "DPECore",
            path: "Sources/DPECore",
            resources: [
                .copy("Resources/timeline.json"),
                // hydra-synth (AGPL-3.0) and the page that hosts it. Copied rather
                // than processed: the library must stay byte-identical to the release
                // it claims to be, and the page loads it by name from the same folder.
                .copy("Resources/hydra-synth.js"),
                .copy("Resources/hydra.html")
            ]
        ),
        .executableTarget(
            name: "GiveIt2Me_DJ_Dave_malware",
            dependencies: ["DPECore"],
            path: "Sources/GiveIt2Me_DJ_Dave_malware",
            exclude: ["Info.plist"],
            // Embed the usage strings into the bare executable: without them macOS kills
            // the process the moment it touches the camera, Contacts or Location Services
            // under `swift run`. (The .app has its own Info.plist — see bundle.sh.)
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate",
                              "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/GiveIt2Me_DJ_Dave_malware/Info.plist"])
            ]
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
