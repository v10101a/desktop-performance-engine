import AppKit
import WebKit

/// A GLSL fragment shader running in a window.
///
/// Same shape as `HydraWebView` and for the same reason: a WKWebView is the one GL
/// surface this app already knows how to put inside an effect window, and `shader.html`
/// is a plain WebGL1 host rather than a library. The shader source is read off disk by
/// Swift and injected as a string — `file://` pages cannot `fetch()` a sibling file, so
/// the page is handed its shader rather than fetching it.
///
/// **No pool, unlike hydra.** Hydra pre-warms canvases because compiling a 205KB library
/// mid-show is a visible drop; this page is 128 lines and the only compile is the
/// artist's own shader, which happens once when the window opens. If the show ever runs
/// several of these at once that judgement should be revisited.
final class ShaderCanvasView: NSView, WKNavigationDelegate {
    private let web: WKWebView
    private var started = false
    private var pending: String?
    /// Degrees per second the canvas turns, 0 for the still shot it was before.
    private var spin = 0.0

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        // No white flash between the window appearing and the first frame.
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The window owns the mouse — a live canvas is scenery, exactly as with hydra.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Turn the picture at `degreesPerSecond`. Applied in the PAGE, not on this view's
    /// layer: rotating the layer means scaling the canvas up so its corners cannot swing
    /// off the window, and that scale crops the shot — the shader composes against
    /// `u_resolution`, so a bigger canvas renders a bigger scene and the window shows
    /// the middle of it. See `withSpin` in shader.html for what happens instead.
    func startSpinning(degreesPerSecond: Double) {
        spin = degreesPerSecond
        if started { applySpin() }
    }

    private func applySpin() {
        guard spin != 0 else { return }
        web.evaluateJavaScript("window.__dpeShaderSpin(\(spin))") { value, _ in
            // A shader with no `gl_FragCoord` or no `u_resolution` cannot be rewritten
            // to turn. Saying so beats a cue that silently holds still.
            if let ok = value as? Bool, !ok {
                NSLog("[DPE] shader: spin ignored — this shader has nothing to rotate")
            }
        }
    }

    /// Load the host page, then the shader at `path` once it is up.
    func load(shaderAt path: String) {
        // `bundledResource`, not `resolveResourcePath`: the host page ships inside the
        // build, it is not an authored asset, so it is not under `assets/`.
        guard let page = bundledResource("shader", "html") else {
            NSLog("[DPE] shader: shader.html is not in this build")
            return
        }
        guard let src = try? String(contentsOfFile: resolveResourcePath(path), encoding: .utf8) else {
            NSLog("[DPE] shader: could not read \(path)")
            return
        }
        pending = src
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    func setUniform(_ name: String, _ value: Double) {
        guard started else { return }
        web.evaluateJavaScript("window.__dpeShaderSet(\(ShaderCanvasView.jsString(name)), \(value))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        started = true
        guard let src = pending else { return }
        pending = nil
        // The page returns its compile error rather than throwing, because a shader that
        // fails to compile renders black — which looks exactly like a shader that renders
        // black. Without this the failure is invisible.
        web.evaluateJavaScript("window.__dpeShader(\(ShaderCanvasView.jsString(src)))") { [weak self] result, error in
            // The spin goes in after the source, not before it: whether this shader can
            // be rewritten to turn is only known once the page has looked at it.
            self?.applySpin()
            if let error {
                // The message, not just "A JavaScript exception occurred" — WebKit puts
                // the real one in userInfo and the description alone says nothing.
                let ns = error as NSError
                let detail = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
                NSLog("[DPE] shader: injection failed — \(detail ?? error.localizedDescription)")
            } else if let s = result as? String, s != "ok" {
                NSLog("[DPE] shader: \(s)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[DPE] shader: page failed to load — \(error.localizedDescription)")
    }

    /// A JS string literal for arbitrary source. JSON encoding, not hand-escaping: the
    /// shader is someone else's file and will contain quotes, backslashes and newlines.
    static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let json = String(data: data, encoding: .utf8),
              json.count > 2 else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}
