import AppKit
import WebKit

/// Actual hydra.
///
/// `Hydra` in HydraView.swift reads a patch and rebuilds it out of CALayers. It is an
/// honest impression and it is still the fallback, but it is an impression: it cannot
/// warp UVs, cannot feed a frame back into itself, cannot run an expression. This runs
/// the real library — ojack's hydra-synth, the same build hydra.ojack.xyz serves — on a
/// WebGL canvas in a WKWebView. Whatever the patch says happens, because the patch is
/// evaluated by hydra rather than read by us.
///
/// PROVENANCE. `Resources/hydra-synth.js` is hydra-synth 1.3.29, unmodified, from
/// https://unpkg.com/hydra-synth@1.3.29/dist/hydra-synth.js
/// sha256 1d7a9871c1840e303fd17c8b3954ff7f80ce922faf9f1b000ad6e30ad0405bc2
/// Nothing is fetched at run time; the piece stays self-contained and offline.
///
/// LICENSING. hydra-synth is AGPL-3.0 and this repository is MIT. Shipping them in one
/// binary makes the distributed work AGPL, which is a decision about how the piece is
/// handed out rather than a detail of how it runs. See README.
///
/// COST, and why this file is mostly about pooling. Every live sketch is a WebGL
/// context, and the show puts nine of them on screen at once in the bar before the
/// drop. Building a WKWebView and compiling a 205KB library takes far longer than a
/// pump tick allows, so the views are made before the clock starts — the same rule the
/// sprite and trail pools follow — handed out as sketches go live, and taken back when
/// their window lets go of them.
///
/// They share one configuration, one process pool and one file origin, in the hope that
/// WebKit would keep them together. Measured, it does not: nine canvases are nine
/// WebContent processes and something over 400MB, and no arrangement of public API
/// changes that. What IS avoidable is the work they do while idle — see `hydra.html`,
/// which drives the render loop itself so a canvas standing by costs a context and
/// nothing more. `--test-hydra` prints the bill on the machine you will perform on.
enum HydraWeb {

    /// Set from the environment once: `DPE_HYDRA=fake` forces the CALayer impression
    /// back on, which is the way to A/B the two on a given machine — and what the still
    /// renderer uses, since an off-screen `cacheDisplay` cannot capture a web view.
    static var enabled: Bool = {
        if let mode = ProcessInfo.processInfo.environment["DPE_HYDRA"] {
            return mode.lowercased() != "fake" && mode.lowercased() != "0"
        }
        return true
    }()

    /// How many live canvases this machine is willing to pay for. Nine of them cost
    /// nine WebContent processes and something like 400MB — WebKit declines to share a
    /// process between them whatever configuration they are handed — and that is a bill
    /// worth being able to cap on the machine the piece is actually performed on.
    /// `DPE_HYDRA_MAX=1` gives the real thing to the first sketch that asks and leaves
    /// the rest on the impression; sketches are served in the order the timeline opens
    /// them, so the cap favours the earliest window rather than the biggest one.
    static let budget: Int = {
        guard let raw = ProcessInfo.processInfo.environment["DPE_HYDRA_MAX"],
              let n = Int(raw), n >= 0 else { return .max }
        return n
    }()

    /// The page every canvas loads. All of them load this same URL so they share an
    /// origin — a unique per-view origin would mean a process and a script compile each.
    private static let pageURL: URL? = resource("hydra", "html")

    /// Read access has to cover the directory, not just the page, or the `<script src>`
    /// inside it is blocked and hydra never defines itself.
    private static var resourceDirectory: URL? { pageURL?.deletingLastPathComponent() }

    /// True when the library actually shipped with this build. If it did not, every
    /// call below is a no-op and the sketches quietly fall back to the impression —
    /// a missing resource should cost fidelity, never the show.
    static var isAvailable: Bool {
        guard enabled, let page = pageURL else { return false }
        return FileManager.default.fileExists(atPath: page.path)
            && FileManager.default.fileExists(
                atPath: page.deletingLastPathComponent().appendingPathComponent("hydra-synth.js").path)
    }

    /// Resolve like the timeline does: the flat `Contents/Resources` of a real .app
    /// first, then SwiftPM's bundle for `swift run` in the tree.
    private static func resource(_ name: String, _ ext: String) -> URL? {
        if let res = Bundle.main.resourceURL {
            // Same resolution order as `bundledTimelineURL`: flat copy, then whichever
            // SwiftPM resource bundle is present, DPECore's first. The bundle name is
            // derived from the package and target, so it is scanned for, not hardcoded.
            let fm = FileManager.default
            let flat = res.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: flat.path) { return flat }
            for b in resourceBundles(in: res, fm: fm) {
                let url = b.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }

    // MARK: - The pool

    /// One shared configuration for every canvas. Same process pool, same content
    /// world, so WebKit can coalesce them instead of standing up nine of everything.
    private static let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        config.suppressesIncrementalRendering = true
        config.websiteDataStore = .nonPersistent()
        return config
    }()

    private static var idle: [HydraCanvasView] = []
    private static var built = 0

    /// Build `count` canvases and let them finish loading while the clock is still
    /// stopped. Called from `WindowManager.prewarm`.
    static func prewarm(count: Int) {
        guard isAvailable, count > 0 else { return }
        let wanted = min(count, budget) - idle.count
        guard wanted > 0 else { return }
        for _ in 0..<wanted { idle.append(make()) }
        NSLog("[DPE] hydra: prewarmed \(idle.count) live canvases (hydra-synth 1.3.29)")
    }

    /// A canvas that has already loaded and started, or a fresh one if the pool ran
    /// dry. Running dry is not fatal, but it means a WKWebView is being built inside a
    /// pump tick, so it says so — the same contract as the micro-window pools.
    static func take() -> HydraCanvasView? {
        guard isAvailable else { return nil }
        if let canvas = idle.popLast() { return canvas }
        guard built < budget else { return nil }      // over budget: fall back, quietly
        NSLog("[DPE] hydra: building a canvas mid-show (pool dry after \(built)) — prewarm more")
        return make()
    }

    /// Handed back when the borrowing window drops it. Reset to black so the next
    /// sketch does not open on the last one's output.
    static func give(_ canvas: HydraCanvasView) {
        guard idle.count < 24 else { return }
        canvas.stop()
        idle.append(canvas)
    }

    private static func make() -> HydraCanvasView {
        built += 1
        let canvas = HydraCanvasView(configuration: configuration)
        if let page = pageURL, let directory = resourceDirectory {
            canvas.load(page: page, readAccess: directory)
        }
        return canvas
    }
}

/// One live sketch: a web view running hydra, with the window's clicks passing
/// straight through it.
final class HydraCanvasView: NSView, WKNavigationDelegate {
    private let web: WKWebView
    private var started = false
    private var pendingPatch: String?
    private var paused = false

    init(configuration: WKWebViewConfiguration) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400),
                        configuration: configuration)
        super.init(frame: web.frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        // No white flash between the window appearing and the first frame: the page is
        // black, and until it draws, the layer under it is too.
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The window owns the mouse. A live sketch is scenery — the viewer drags this
    /// window by its background and closes it by its fake traffic lights, exactly like
    /// every other window in the piece, and a web view that swallowed clicks would
    /// quietly break both.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func load(page: URL, readAccess: URL) {
        web.loadFileURL(page, allowingReadAccessTo: readAccess)
    }

    /// Run a patch. Before the page is up this is remembered and run on arrival, so a
    /// canvas can be handed a sketch the instant it is taken from the pool.
    func run(_ patch: String) {
        guard started else {
            pendingPatch = patch
            return
        }
        evaluate("window.__dpeRun(\(HydraCanvasView.jsString(patch)))", label: "run")
    }

    func stop() {
        pendingPatch = nil
        paused = false
        guard started else { return }
        evaluate("window.__dpeStop()", label: "stop")
    }

    /// Rendered-frame count and hydra's clock, as `"ticks:time"`. Proof for
    /// `--test-pause` that a frozen canvas really has stopped rendering.
    func readTicks(_ done: @escaping (String) -> Void) {
        guard started else { done("not-started"); return }
        web.evaluateJavaScript("window.__dpeTicks()") { result, _ in
            done(result as? String ?? "?")
        }
    }

    /// Freeze the sketch on its current frame, keeping it loaded. `layer.speed = 0`
    /// cannot reach a live canvas — the page renders in its own process off its own
    /// rAF loop — so the transport's Pause has to tell it directly, or the hydra stack
    /// carries on spinning over a stopped clock.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        guard started else { return }     // applied on arrival instead
        evaluate("window.__dpeSetPaused(\(paused))", label: "setPaused")
    }

    /// Hand the canvas back the moment its window lets go of it — a livecode window
    /// that is re-opened (which is how the show "runs" a sketch) throws its whole
    /// content view away, and this is that moment.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { HydraWeb.give(self) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let size = bounds.size
        let w = Int(max(160, size.width.rounded()))
        let h = Int(max(120, size.height.rounded()))
        evaluate("window.__dpeStart(\(w), \(h))", label: "start") { [weak self] in
            guard let self = self else { return }
            self.started = true
            if let patch = self.pendingPatch {
                self.pendingPatch = nil
                self.run(patch)
            }
            // Taken from the pool while the show was already paused: the sketch must
            // arrive frozen, not start running under a held playhead.
            if self.paused { self.setPaused(true) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[DPE] hydra: page failed — \(error.localizedDescription)")
    }

    /// Every bridge call returns a message string rather than throwing, so a patch with
    /// a typo in it shows up in the log instead of silently rendering nothing. The
    /// window keeps whatever it had; a broken sketch is a black rectangle with the code
    /// still printed over it, which is also what the website does.
    private func evaluate(_ js: String, label: String, then: (() -> Void)? = nil) {
        web.evaluateJavaScript(js) { result, error in
            if let error = error {
                NSLog("[DPE] hydra \(label): \(error.localizedDescription)")
            } else if let message = result as? String, !message.isEmpty {
                NSLog("[DPE] hydra \(label): \(message)")
            }
            then?()
        }
    }

    /// The patch travels into the page as a JS string literal, so quotes, newlines and
    /// backslashes in a sketch cannot break out of it.
    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8),
              json.count > 2 else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}
