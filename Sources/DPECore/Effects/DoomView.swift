import AppKit
import WebKit

/// DooM, running in one of the show's windows.
///
/// Same shape as `ShaderCanvasView` and `HydraWebView`: a WKWebView is the surface this
/// app already knows how to put inside an effect window, and `doom.html` is the host —
/// see that page for what the module imports and exports. The engine binary is fetched
/// rather than committed (`tools/fetch_doom.sh`); with it missing the page says so in
/// the window instead of sitting black, which is the difference between "not installed"
/// and "broken" at a glance.
///
/// **Served over a custom scheme, not `file://`.** The page has to `fetch()` a 6.5 MB
/// sibling to instantiate it, and a file:// page cannot fetch its own directory without
/// the private `allowFileAccessFromFileURLs` switch. A `WKURLSchemeHandler` is the
/// supported way to do this: page and engine come from one origin that is ours, and the
/// handler serves exactly two files out of the build's resources and nothing else.
final class DoomView: NSView {
    private let web: WKWebView

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        config.setURLSchemeHandler(DoomResourceHandler(), forURLScheme: DoomResourceHandler.scheme)
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        web.load(URLRequest(url: DoomResourceHandler.pageURL))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Scenery, like every other live canvas in the piece: it must not take the clicks
    /// of a viewer who is trying to drag the window it is in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Test seam for `--test-doom`: what the page can see about itself — whether the
    /// module booted, and how much of the canvas is actually lit. A window that opens
    /// on a black canvas and a window that opens on DooM look identical from Swift.
    func report(_ done: @escaping (String) -> Void) {
        let js = """
        (function () {
          var c = document.getElementById('screen');
          var d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
          var lit = 0, n = 0;
          for (var i = 0; i < d.length; i += 4 * 97) { n++; if (d[i] + d[i+1] + d[i+2] > 24) lit++; }
          return JSON.stringify({
            installed: document.getElementById('missing').style.display !== 'block',
            error: window.__doomError || null, lit: lit, samples: n
          });
        })()
        """
        web.evaluateJavaScript(js) { value, error in
            done((value as? String) ?? "error: \(error?.localizedDescription ?? "no value")")
        }
    }

    /// The canvas as PNG bytes, straight out of the page. A lit-pixel count cannot tell
    /// the title screen from a firefight; this can.
    func snapshot(_ done: @escaping (Data?) -> Void) {
        web.evaluateJavaScript("document.getElementById('screen').toDataURL('image/png')") { v, _ in
            guard let s = v as? String, let comma = s.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else {
                done(nil); return
            }
            done(data)
        }
    }

    /// Whether the engine is actually installed. The window is built either way — the
    /// page explains itself — but the show's tests and `--test-doom` want to know.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: DoomResourceHandler.enginePath)
    }
}

/// Serves `doom.html` and `doom.wasm` out of the build's resources, and nothing else.
final class DoomResourceHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "dpedoom"
    static let pageURL = URL(string: "\(scheme)://engine/doom.html")!

    /// The engine, by the path the fetch script installs it at. An asset rather than a
    /// build resource — see `tools/fetch_doom.sh` for why.
    static var enginePath: String { resolveResourcePath("assets/doom.wasm") }

    /// The whole vocabulary of this origin. A request for anything else is refused
    /// rather than resolved: the handler is a door onto the disk, and it only ever
    /// needs to open onto these two files.
    private static func url(for path: String) -> (URL, String)? {
        switch path {
        case "/doom.html":
            return bundledResource("doom", "html").map { ($0, "text/html") }
        case "/doom.wasm":
            let p = enginePath
            guard FileManager.default.fileExists(atPath: p) else { return nil }
            return (URL(fileURLWithPath: p), "application/wasm")
        default:
            return nil
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let path = task.request.url?.path ?? ""
        guard let want = DoomResourceHandler.url(for: path),
              let data = try? Data(contentsOf: want.0) else {
            // A 404 the page can catch: `instantiateStreaming` rejects, and doom.html
            // puts up the "not installed" card.
            task.didReceive(HTTPURLResponse(url: task.request.url ?? DoomResourceHandler.pageURL,
                                            statusCode: 404, httpVersion: "HTTP/1.1",
                                            headerFields: nil)!)
            task.didFinish()
            return
        }
        // An HTTPURLResponse with a real Content-Type header, NOT a plain URLResponse
        // with a mimeType: `WebAssembly.instantiateStreaming` reads the header, and with
        // the bare URLResponse it rejects every module with "Unexpected response MIME
        // type. Expected 'application/wasm'" — which arrives as a blank window.
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": want.1,
                                                      "Content-Length": String(data.count)])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
