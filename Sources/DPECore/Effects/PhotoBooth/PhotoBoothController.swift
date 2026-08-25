import AppKit
import AVFoundation

/// The one photo the show takes, held in memory for the credits. Never written to
/// disk; `discard()` is called when the show stops or is panicked, so nothing of the
/// viewer survives the piece unless they screenshot the end card themselves.
final class PhotoBoothStore {
    static let shared = PhotoBoothStore()
    private(set) var image: NSImage?
    private(set) var takenAt: Date?

    func keep(_ image: NSImage) {
        self.image = image
        takenAt = Date()
    }

    func discard() {
        image = nil
        takenAt = nil
    }
}

/// Photo Booth: the viewer's own camera in a window, a countdown in tempo, a photo on
/// the last beat. The preview is mirrored the way Photo Booth mirrors it, and the
/// photo is mirrored to match, so what they see is what they get.
///
/// The capture session is configured at `prewarm` (device discovery and session
/// configuration are slow) and started when the event fires — so the camera light
/// comes on when the window opens, not for the whole show.
///
/// Camera access: asked for at the intro gate by `Permissions.preflight`; refused, or
/// with no camera at all, the preview says so and the countdown runs anyway. Nothing
/// else in the piece depends on there being a picture.
final class PhotoBoothController: NSObject, AVCapturePhotoCaptureDelegate {
    /// When each countdown number appears and when the shutter fires, in seconds after
    /// the event. Pure arithmetic, split out so the tests can check the timing.
    struct Plan {
        let numberAt: [Double]    // numberAt[0] is when `count` shows, the last is when 1 shows
        let shutterAt: Double
        let count: Int

        init(_ p: PhotoBoothParams, bpm: Double) {
            let total = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm) ?? 16 * 60 / bpm
            let step = (p.stepBeats ?? 4) * 60 / max(1, bpm)
            let n = max(1, p.count ?? 3)
            count = n
            shutterAt = total
            numberAt = (0..<n).map { total - Double(n - $0) * step }
        }

        /// The number on screen at `t`, or nil (before the countdown, and after the shutter).
        func number(at t: Double) -> Int? {
            guard t < shutterAt else { return nil }
            var shown: Int?
            for (i, at) in numberAt.enumerated() where t >= at { shown = count - i }
            return shown
        }
    }

    private struct Booth {
        let id: String
        let window: BaseEffectWindow
        let view: BoothView
        let plan: Plan
        let start: Double
        let flash: NSColor
        let hold: Bool
        var shownNumber: Int? = nil
        var fired = false
        var endTime: Double?
    }

    private var booth: Booth?
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.computerart.dpe.booth", qos: .userInitiated)
    private var configured = false
    private var hasCamera = false
    private var mirror = true
    var bpm: Double = 120

    // MARK: - Prewarm

    /// Configure the session now if the show has a booth in it — before the clock runs.
    func prewarm(for events: [ResolvedEvent]) {
        guard events.contains(where: { if case .photoBooth = $0.action { return true }; return false }) else { return }
        guard !configured else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.configure() }
        case .notDetermined:
            // The gate normally asks first; this is the `--no-gate` dev path.
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { self.queue.async { self.configure() } }
            }
        default:
            break
        }
    }

    /// On `queue`. Idempotent.
    private func configure() {
        guard !configured else { return }
        configured = true
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            NSLog("[DPE] photoBooth: no camera")
            return
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        hasCamera = true
    }

    // MARK: - Lifecycle

    func begin(_ p: PhotoBoothParams, at now: Double, bpm: Double) {
        teardown()
        let screen = ScreenGeometry.screen(p.screen)
        let frame = ScreenGeometry.rectOrCentred(p.frame, size: NSSize(width: 640, height: 500), on: screen)
        mirror = p.mirror ?? true

        let contentSize = BaseEffectWindow.contentSize(forFrame: frame, native: true)
        let view = BoothView(size: contentSize, session: session, mirror: mirror)
        let window = HostedEffectWindow(contentRect: frame, view: view, title: p.title ?? "Photo Booth")
        window.present(animate: "springIn")

        let plan = Plan(p, bpm: bpm)
        booth = Booth(id: p.id, window: window, view: view, plan: plan, start: now,
                      flash: NSColor(hex: p.flash ?? "#FFFFFF") ?? .white,
                      hold: p.hold ?? false)

        queue.async { [self] in
            configure()
            let live = hasCamera
            if live && !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.booth?.id == p.id else { return }
                self.booth?.view.setCameraAvailable(live)
            }
        }
    }

    func stop(id: String) {
        guard booth?.id == id else { return }
        teardown()
    }

    func closeAll() { teardown() }

    private func teardown() {
        guard let b = booth else { return }
        b.window.orderOut(nil)
        booth = nil
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    // MARK: - Tick

    func update(now: Double) {
        guard var b = booth else { return }
        if let end = b.endTime, now >= end {
            teardown()
            return
        }
        let t = now - b.start
        let n = b.plan.number(at: t)
        if n != b.shownNumber {
            b.shownNumber = n
            b.view.show(number: n)
        }
        if !b.fired && t >= b.plan.shutterAt {
            b.fired = true
            capture()
            b.view.flash(b.flash)
            if !b.hold { b.endTime = now + 0.22 }   // the window goes with the flash
        }
        booth = b
    }

    private func capture() {
        guard hasCamera, session.isRunning else { return }
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { NSLog("[DPE] photoBooth: capture failed: \(error.localizedDescription)"); return }
        guard let data = photo.fileDataRepresentation(), var image = NSImage(data: data) else { return }
        if mirror { image = PhotoBoothController.mirrored(image) }
        PhotoBoothStore.shared.keep(image)
        DispatchQueue.main.async { [weak self] in
            guard let self, let b = self.booth, b.hold else { return }
            b.view.freeze(image)
        }
    }

    /// Flip horizontally, so the kept photo matches the mirrored preview.
    static func mirrored(_ image: NSImage) -> NSImage {
        let size = image.size
        let out = NSImage(size: size)
        out.lockFocus()
        let t = NSAffineTransform()
        t.translateX(by: size.width, yBy: 0)
        t.scaleX(by: -1, yBy: 1)
        t.concat()
        image.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        return out
    }
}

/// The booth's content: the live preview filling the top, a strip with a shutter
/// button along the bottom, the countdown numeral over the middle, and a flash layer.
final class BoothView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let numeral = NSTextField(labelWithString: "")
    private let flashLayer = CALayer()
    private let notice = NSTextField(labelWithString: "")
    private let strip = NSView()
    private let frozen = NSImageView()

    init(size: NSSize, session: AVCaptureSession, mirror: Bool) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let stripH: CGFloat = 58
        let stage = NSRect(x: 0, y: stripH, width: size.width, height: size.height - stripH)

        preview.frame = stage
        preview.videoGravity = .resizeAspectFill
        if mirror {
            // A transform rather than the connection's mirroring flag: the connection
            // only exists once the session has an input, which may be a moment away.
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        }
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(preview)

        frozen.frame = stage
        frozen.imageScaling = .scaleProportionallyUpOrDown
        frozen.autoresizingMask = [.width, .height]
        frozen.isHidden = true
        addSubview(frozen)

        notice.stringValue = "warming up the camera…"
        notice.font = .systemFont(ofSize: 14, weight: .medium)
        notice.textColor = NSColor(white: 1, alpha: 0.55)
        notice.alignment = .center
        notice.frame = NSRect(x: 0, y: stage.minY + 16, width: size.width, height: 24)
        notice.autoresizingMask = [.width, .maxYMargin]
        addSubview(notice)

        // Photo Booth's bottom bar: dark, with the big red shutter button in the middle.
        strip.frame = NSRect(x: 0, y: 0, width: size.width, height: stripH)
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        strip.autoresizingMask = [.width, .maxYMargin]
        addSubview(strip)
        let shutter = NSView(frame: NSRect(x: (size.width - 62) / 2, y: 10, width: 62, height: 38))
        shutter.wantsLayer = true
        shutter.layer?.backgroundColor = NSColor(red: 0.85, green: 0.12, blue: 0.10, alpha: 1).cgColor
        shutter.layer?.cornerRadius = 8
        shutter.autoresizingMask = [.minXMargin, .maxXMargin]
        let cam = NSImageView(frame: shutter.bounds.insetBy(dx: 18, dy: 9))
        cam.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)
        cam.contentTintColor = .white
        cam.imageScaling = .scaleProportionallyUpOrDown
        shutter.addSubview(cam)
        strip.addSubview(shutter)

        numeral.font = .systemFont(ofSize: stage.height * 0.5, weight: .heavy)
        numeral.textColor = .white
        numeral.alignment = .center
        numeral.frame = stage
        numeral.autoresizingMask = [.width, .height]
        numeral.wantsLayer = true
        numeral.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.7)
            s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
        addSubview(numeral)

        flashLayer.frame = bounds
        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        flashLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(flashLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setCameraAvailable(_ live: Bool) {
        notice.stringValue = live ? "" : "no camera — the machine can't see you"
        notice.isHidden = live
    }

    func show(number: Int?) {
        numeral.stringValue = number.map(String.init) ?? ""
        guard number != nil, let layer = numeral.layer else { return }
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.35
        pop.toValue = 1.0
        pop.duration = 0.18
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pop, forKey: "pop")
    }

    func flash(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashLayer.backgroundColor = color.cgColor
        flashLayer.opacity = 1
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.45
        fade.beginTime = CACurrentMediaTime() + 0.08
        fade.fillMode = .backwards
        flashLayer.opacity = 0
        flashLayer.add(fade, forKey: "flash")
    }

    /// Hold the taken photo over the live preview.
    func freeze(_ image: NSImage) {
        frozen.image = image
        frozen.isHidden = false
    }
}
