import Foundation

/// A minimal assertion harness. Not XCTest because the Command Line Tools toolchain
/// ships neither XCTest nor swift-testing — `swift test` cannot work without a full
/// Xcode install. Named checks, real failures, a non-zero exit code: `swift run dpe-tests`.
///
/// The tests live inside DPECore rather than a separate target because without a test
/// target there is no `@testable import`, and making every tested type public would be
/// a far larger change to the library's surface.
public final class TestHarness {
    private var passed = 0
    private var failures: [String] = []
    private var currentSuite = ""

    public init() {}

    public func suite(_ name: String, _ body: (TestHarness) -> Void) {
        currentSuite = name
        body(self)
    }

    public func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition { passed += 1 } else { failures.append("\(currentSuite): \(message())") }
    }

    public func equal<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String) {
        expect(a == b, "\(message()) — got \(a), expected \(b)")
    }

    /// Floating-point comparison with an explicit tolerance. Several properties here are
    /// only true within one unit (accumulated `1/72` error), and saying so in the test is
    /// better than asserting something false.
    public func near(_ a: Double, _ b: Double, _ tolerance: Double,
                     _ message: @autoclosure () -> String) {
        expect(abs(a - b) <= tolerance,
               "\(message()) — got \(a), expected \(b) ± \(tolerance)")
    }

    public func near(_ a: Int, _ b: Int, _ tolerance: Int, _ message: @autoclosure () -> String) {
        near(Double(a), Double(b), Double(tolerance), message())
    }

    public func notNil<T>(_ value: T?, _ message: @autoclosure () -> String) {
        expect(value != nil, "\(message()) — was nil")
    }

    /// Prints a report and returns the number of failures, for the process exit code.
    public func report() -> Int {
        let total = passed + failures.count
        if failures.isEmpty {
            print("\u{001B}[32m✓ \(total) checks passed\u{001B}[0m")
        } else {
            print("\u{001B}[31m✗ \(failures.count) of \(total) checks FAILED\u{001B}[0m")
            for f in failures { print("  • \(f)") }
        }
        return failures.count
    }
}

/// Entry point for the `dpe-tests` executable.
public enum UnitTests {
    public static func runAll() -> Int {
        let t = TestHarness()
        CadenceTests.run(t)
        TimelineTests.run(t)
        PhotoWallAlgorithmTests.run(t)
        FileSwarmPatternTests.run(t)
        GlitchEngineTests.run(t)
        DesktopLayerTests.run(t)
        AsciiLogTests.run(t)
        LyricFontTests.run(t)
        ScreenGeometryTests.run(t)
        SystemProbeTests.run(t)
        RendererTests.run(t)
        WindowOwnershipTests.run(t)
        ChromeTests.run(t)
        CreditsTests.run(t)
        GateTests.run(t)
        PermissionsTests.run(t)
        ProductionTests.run(t)
        SegCamTests.run(t)
        return t.report()
    }
}
