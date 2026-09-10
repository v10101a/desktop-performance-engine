import AppKit
import AVFoundation
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers

let appName = "Insta360 Pan"

/// Everything `insta360pan --help` lists. Works through Finder too:
/// `open insta360pan.app --args --test`.
struct LaunchOptions {
    var cameraName: String?
    var testScene = false
    var file: URL?
    var outputSize = SIMD2<Int>(1920, 1080)
    var syphonName = "Insta360 Pan"
    var snapshot: URL?
    var yaw: Double?
    var pitch: Double?
    var zoom: Double?
    var rectilinear = false
    var raw = false
    var openCalibration = false
    var calibrationFile: URL?
    var freshCalibration = false
    var overrides: [(inout Calibration) -> Void] = []
    var showHelp = false

    static let usage = """
    usage: insta360pan [options]
      --camera NAME        open the camera whose name contains NAME
                           (default: the Insta360 if present, else the first external camera)
      --test               show the synthetic test scene instead of a camera
      --file PATH          loop a video file (a recording of the webcam feed) instead of a camera
      --size WxH           Syphon output frame size (default 1920x1080)
      --name NAME          Syphon server name (default "Insta360 Pan")
      --yaw DEG            starting yaw; 0 = front-lens axis, positive = right
      --pitch DEG          starting pitch; positive = up
      --zoom Z             starting zoom; 1 = the band's full height fills the frame
      --rect               rectilinear (virtual camera) view instead of the loop
      --raw                show the frame as it arrives, with the lens model drawn over it
      --calibrate          open the lens calibration panel at launch
      --snapshot PATH      render one output frame to a PNG at PATH and quit
    lens model (saved as it changes to ~/Library/Application Support/insta360pan/calibration.json):
      --calibration PATH   load and save the lens model here instead
      --fresh              ignore the saved lens model; start from the defaults
      --fov DEG            lens field of view at the edge of its image circle
      --projection NAME    equidistant | equisolid | stereographic | orthographic
      --circle CX,CY,RX,RY image circle in a 1920×540 half: centre and radii, pixels
      --blend DEG          seam cross-fade width
      --distance M         stitch distance: things this far away join up across the seams
      --baseline M         distance between the two lenses' pupils
      --swap               the rear lens is the top half of the frame
      --mirror-front       the front lens's image reads backwards
      --mirror-rear        the rear lens's image reads backwards
    """

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        func value() -> String? { i + 1 < arguments.count ? arguments[i + 1] : nil }
        func number() -> Double? { value().flatMap(Double.init) }
        while i < arguments.count {
            switch arguments[i] {
            case "--camera": o.cameraName = value(); i += 1
            case "--test": o.testScene = true
            case "--file": if let v = value() { o.file = URL(fileURLWithPath: v) }; i += 1
            case "--size":
                if let v = value() {
                    let parts = v.lowercased().split(separator: "x")
                    if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                        o.outputSize = [w, h]
                    }
                }
                i += 1
            case "--name": if let v = value() { o.syphonName = v }; i += 1
            case "--yaw", "--heading": o.yaw = number(); i += 1
            case "--pitch": o.pitch = number(); i += 1
            case "--zoom": o.zoom = number(); i += 1
            case "--rect": o.rectilinear = true
            case "--raw": o.raw = true
            case "--calibrate": o.openCalibration = true
            case "--snapshot": if let v = value() { o.snapshot = URL(fileURLWithPath: v) }; i += 1
            case "--calibration": if let v = value() { o.calibrationFile = URL(fileURLWithPath: v) }; i += 1
            case "--fresh": o.freshCalibration = true
            case "--fov": if let v = number() { o.overrides.append { $0.fovDegrees = v } }; i += 1
            case "--projection":
                if let v = value(), let p = Calibration.Projection(rawValue: v.lowercased()) {
                    o.overrides.append { $0.projection = p }
                }
                i += 1
            case "--circle":
                if let v = value() {
                    let parts = v.split(separator: ",").compactMap { Double($0) }
                    if parts.count == 4 {
                        o.overrides.append {
                            $0.circleCenterX = parts[0]; $0.circleCenterY = parts[1]
                            $0.circleRadiusX = parts[2]; $0.circleRadiusY = parts[3]
                        }
                    }
                }
                i += 1
            case "--blend": if let v = number() { o.overrides.append { $0.blendDegrees = v } }; i += 1
            case "--distance": if let v = number() { o.overrides.append { $0.stitchDistanceMetres = v } }; i += 1
            case "--baseline": if let v = number() { o.overrides.append { $0.baselineMetres = v } }; i += 1
            case "--swap": o.overrides.append { $0.swapHalves = true }
            case "--mirror-front": o.overrides.append { $0.mirrorFront = true }
            case "--mirror-rear": o.overrides.append { $0.mirrorRear = true }
            case "--help", "-h": o.showHelp = true
            default: break        // LaunchServices passes -psn_… and the like
            }
            i += 1
        }
        return o
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MTKViewDelegate {
    private let options: LaunchOptions
    private var window: NSWindow!
    private var stitchView: StitchView!
    private let bar = ControlBar()
    private var renderer: StitchRenderer!
    private var syphon: SyphonOutput?
    private var panel: CalibrationPanel?

    private let camera = Camera()
    private var synthetic: SyntheticSource?
    private var fileSource: FileSource?
    private var source: FrameSource?

    private var calibrationURL = Calibration.defaultFileURL
    private var saveTimer: Timer?
    private var keyMonitor: Any?
    private var statusTimer: Timer?
    private var fps = 0.0
    private var lastStatusTick = Date()
    private var sourceMenu: NSMenu?
    private var toggles: [String: NSMenuItem] = [:]
    private var sizeItems: [NSMenuItem] = []

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { fail("This Mac has no Metal device.") }
        syphon = SyphonOutput(name: options.syphonName)
        do {
            renderer = try StitchRenderer(device: device, syphon: syphon)
        } catch {
            fail("Could not build the Metal pipeline:\n\(error.localizedDescription)")
        }

        // The lens model: the saved one unless told otherwise, then the command line on top.
        if let file = options.calibrationFile { calibrationURL = file }
        var calibration = Calibration()
        if !options.freshCalibration, let loaded = try? Calibration.load(from: calibrationURL) {
            calibration = loaded
        }
        for override in options.overrides { override(&calibration) }
        renderer.calibration = calibration
        renderer.rawView = options.raw
        renderer.setOutputSize(options.outputSize)
        renderer.viewport.rectilinear = options.rectilinear
        if let yaw = options.yaw { renderer.viewport.yaw = yaw }
        if let pitch = options.pitch { renderer.viewport.pitch = pitch }
        if let zoom = options.zoom { renderer.viewport.zoom = zoom }
        renderer.viewport.normalise()

        stitchView = StitchView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), device: device)
        stitchView.renderer = renderer
        stitchView.delegate = self
        stitchView.onInteraction = { [weak self] in self?.refreshStatus() }

        bar.outputSize = options.outputSize
        bar.onOutputSize = { [weak self] size in self?.setOutputSize(size) }
        bar.onRectilinear = { [weak self] on in self?.setRectilinear(on) }
        bar.onRaw = { [weak self] on in self?.setRaw(on) }
        bar.onLayout = { [weak self] swap, front, rear in
            self?.mutateCalibration { $0.swapHalves = swap; $0.mirrorFront = front; $0.mirrorRear = rear }
        }
        bar.onCalibrate = { [weak self] in self?.showCalibration() }
        bar.onReset = { [weak self] in self?.resetView() }
        bar.onSource = { [weak self] choice in self?.choose(choice) }
        bar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = NSStackView(views: [stitchView, bar])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.distribution = .fill
        stack.detachesHiddenViews = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = stack
        window.minSize = NSSize(width: 760, height: 420)
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("Insta360PanWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(stitchView)

        camera.onDevicesChanged = { [weak self] in self?.refreshSourceLists() }
        buildMenu()
        syncControls()
        chooseInitialSource()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tickStatus()
        }
        NSApp.activate(ignoringOtherApps: true)
        if options.openCalibration { showCalibration() }

        if let path = options.snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.writeSnapshot(to: path) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if saveTimer != nil { saveCalibration() }
        source?.stop()
        syphon?.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func fail(_ message: String) -> Never {
        if options.snapshot != nil {
            print("error: \(message)")
        } else {
            let alert = NSAlert()
            alert.messageText = appName
            alert.informativeText = message
            alert.runModal()
        }
        exit(1)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.markDirty()
    }

    func draw(in view: MTKView) {
        renderer.draw(in: view)
    }

    // MARK: - Sources

    /// Decided before anything starts: `--test` and `--file` never touch the camera, so
    /// there is no permission prompt and the camera stays free.
    private func chooseInitialSource() {
        if let url = options.file {
            useFile(url)
        } else if options.testScene {
            useTestScene()
        } else {
            if let name = options.cameraName {
                camera.userChoseDevice = camera.preferDevice(matching: name)
            }
            useCamera()
        }
    }

    private func use(_ next: FrameSource) {
        if let source, source !== next { source.stop() }
        source = next
        next.onFrame = { [weak self] buffer in self?.renderer.submit(buffer) }
        next.onStatus = { [weak self] message in self?.bar.message = message }
        bar.message = nil
        next.start()
        refreshSourceLists()
    }

    private func useCamera(_ device: AVCaptureDevice? = nil) {
        if let device {
            camera.userChoseDevice = true
            camera.select(device)
        }
        use(camera)
    }

    private func useTestScene() {
        let scene = synthetic ?? SyntheticSource(renderer: renderer)
        synthetic = scene
        use(scene)
    }

    private func useFile(_ url: URL) {
        let file = FileSource(url: url)
        fileSource = file
        use(file)
    }

    private func choose(_ choice: ControlBar.SourceChoice) {
        switch choice {
        case .camera(let id):
            if let device = Camera.availableDevices().first(where: { $0.uniqueID == id }) { useCamera(device) }
        case .testScene:
            useTestScene()
        case .openFile:
            openFile()
        }
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "A recording of the Insta360's webcam feed"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                self?.refreshSourceLists()
                return
            }
            self?.useFile(url)
        }
    }

    private var isCameraSource: Bool { source === camera }
    private var isTestScene: Bool { synthetic != nil && source === synthetic }
    private var isFileSource: Bool { fileSource != nil && source === fileSource }

    private func refreshSourceLists() {
        let cameras = Camera.availableDevices().map { (id: $0.uniqueID, name: $0.localizedName) }
        bar.setSources(
            cameras: cameras,
            current: isCameraSource ? camera.currentDeviceID : nil,
            testScene: isTestScene,
            file: isFileSource ? fileSource?.name : nil)
        rebuildSourceMenu(cameras: cameras)
        window.title = "\(appName) — \(source?.name ?? "no source") → Syphon “\(options.syphonName)”"
    }

    // MARK: - Calibration and view

    /// One path for every change to the lens model, wherever it came from: the renderer
    /// gets it, the bar and the panel follow, and it goes to disk shortly after.
    private func apply(_ calibration: Calibration) {
        renderer.calibration = calibration
        syncControls()
        scheduleSave()
        refreshStatus()
    }

    private func mutateCalibration(_ change: (inout Calibration) -> Void) {
        var c = renderer.calibration
        change(&c)
        apply(c)
    }

    private func syncControls() {
        let c = renderer.calibration
        bar.swapHalves = c.swapHalves
        bar.mirrorFront = c.mirrorFront
        bar.mirrorRear = c.mirrorRear
        bar.rectilinear = renderer.viewport.rectilinear
        bar.raw = renderer.rawView
        panel?.calibration = c
        syncMenus()
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.saveCalibration()
        }
    }

    private func saveCalibration() {
        saveTimer?.invalidate()
        saveTimer = nil
        do {
            try renderer.calibration.save(to: calibrationURL)
        } catch {
            bar.message = "Could not save the lens model: \(error.localizedDescription)"
        }
    }

    private func showCalibration() {
        if panel == nil {
            let p = CalibrationPanel(calibration: renderer.calibration)
            p.onChange = { [weak self] calibration in self?.apply(calibration) }
            panel = p
        }
        panel?.calibration = renderer.calibration
        panel?.orderFront(nil)
    }

    private func setRectilinear(_ on: Bool) {
        renderer.viewport.rectilinear = on
        renderer.viewport.normalise()
        syncControls()
        refreshStatus()
    }

    private func setRaw(_ on: Bool) {
        renderer.rawView = on
        syncControls()
        refreshStatus()
    }

    private func setOutputSize(_ size: SIMD2<Int>) {
        renderer.setOutputSize(size)
        bar.outputSize = size
        syncMenus()
        refreshStatus()
    }

    private func resetView() {
        renderer.viewport.reset()
        refreshStatus()
    }

    private func zoom(by factor: Double) {
        renderer.viewport.zoom(by: factor, anchor: stitchView.centerPixel)
        refreshStatus()
    }

    /// Look `dx`, `dy` frame-widths/heights to the right/down.
    private func nudge(dx: Double = 0, dy: Double = 0) {
        renderer.viewport.pan(byOutputPixels: [-dx * Double(renderer.outputSize.x), -dy * Double(renderer.outputSize.y)])
        refreshStatus()
    }

    // MARK: - Status

    private func tickStatus() {
        let now = Date()
        let dt = now.timeIntervalSince(lastStatusTick)
        lastStatusTick = now
        let instant = dt > 0 ? Double(renderer.takeFrameCount()) / dt : 0
        fps = fps * 0.7 + instant * 0.3
        refreshStatus()
    }

    private func refreshStatus() {
        let v = renderer.viewport
        let frame = renderer.frameSize
        var parts: [String] = []
        parts.append(frame.x > 0 ? "\(frame.x)×\(frame.y) \(Int(fps.rounded()))fps" : "waiting for frames")
        if renderer.rawView {
            parts.append("raw")
        } else {
            parts.append(String(format: "%.2f×", v.zoom))
            parts.append(String(format: "yaw %+.0f°", v.yaw))
            parts.append(String(format: "pitch %+.0f°", v.pitch))
        }
        if let syphon {
            parts.append(syphon.hasClients ? "Syphon: client" : "Syphon: idle")
        }
        bar.status = parts.joined(separator: " · ")
    }

    // MARK: - Keys

    private func handle(_ event: NSEvent) -> Bool {
        guard window.isKeyWindow, !event.modifierFlags.contains(.command) else { return false }
        let step = 0.08
        switch event.keyCode {
        case 123: nudge(dx: -step); return true       // ←
        case 124: nudge(dx: step); return true        // →
        case 125: nudge(dy: step); return true        // ↓
        case 126: nudge(dy: -step); return true       // ↑
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r", "0": resetView()
        case "=", "+": zoom(by: 1.25)
        case "-", "_": zoom(by: 0.8)
        case "s": mutateCalibration { $0.swapHalves.toggle() }
        case "m": mutateCalibration { $0.mirrorFront.toggle() }
        case "n": mutateCalibration { $0.mirrorRear.toggle() }
        case "x": setRaw(!renderer.rawView)
        case "v": setRectilinear(!renderer.viewport.rectilinear)
        case "k": showCalibration()
        case "[": mutateCalibration { $0.blendDegrees = max(0, $0.blendDegrees - 1) }
        case "]": mutateCalibration { $0.blendDegrees = min(40, $0.blendDegrees + 1) }
        case ",": mutateCalibration { $0.stitchDistanceMetres = max(0.2, $0.stitchDistanceMetres / 1.25) }
        case ".": mutateCalibration { $0.stitchDistanceMetres = min(50, $0.stitchDistanceMetres * 1.25) }
        case "d":
            camera.cycleDevice()
            if !isCameraSource { useCamera() }
        case "c": useCamera()
        case "p": useTestScene()
        case "h": bar.isHidden.toggle()
        default: return false
        }
        return true
    }

    // MARK: - Menus

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let sourceItem = NSMenuItem()
        main.addItem(sourceItem)
        let sourceMenu = NSMenu(title: "Source")
        sourceItem.submenu = sourceMenu
        self.sourceMenu = sourceMenu

        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                  modifiers: NSEvent.ModifierFlags = [.command], id: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
            if let id { toggles[id] = item }
        }

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        item(view, "Zoom In", #selector(menuZoomIn), "=")
        item(view, "Zoom Out", #selector(menuZoomOut), "-")
        item(view, "Reset View", #selector(menuReset), "0")
        view.addItem(.separator())
        item(view, "Loop", #selector(menuLoop), "", id: "loop")
        item(view, "Rectilinear", #selector(menuRectilinear), "", id: "rect")
        item(view, "Raw Frame", #selector(menuRaw), "x", modifiers: [], id: "raw")
        item(view, "Lens Overlay on Raw Frame", #selector(menuOverlay), "", id: "overlay")
        view.addItem(.separator())
        let sizeItem = NSMenuItem(title: "Output Size", action: nil, keyEquivalent: "")
        let sizes = NSMenu(title: "Output Size")
        for (index, size) in ControlBar.outputSizes.enumerated() {
            let item = NSMenuItem(title: "\(size.x)×\(size.y)", action: #selector(menuSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            sizes.addItem(item)
            sizeItems.append(item)
        }
        sizeItem.submenu = sizes
        view.addItem(sizeItem)
        view.addItem(.separator())
        item(view, "Show/Hide Controls", #selector(menuToggleBar), "h", modifiers: [])
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)

        let lensItem = NSMenuItem()
        main.addItem(lensItem)
        let lens = NSMenu(title: "Lens")
        lensItem.submenu = lens
        item(lens, "Calibration…", #selector(menuCalibration), "k")
        lens.addItem(.separator())
        item(lens, "Swap Halves", #selector(menuSwap), "s", modifiers: [], id: "swap")
        item(lens, "Mirror Front Lens", #selector(menuMirrorFront), "m", modifiers: [], id: "front")
        item(lens, "Mirror Rear Lens", #selector(menuMirrorRear), "n", modifiers: [], id: "rear")
        lens.addItem(.separator())
        item(lens, "Reset Lens Model to Defaults", #selector(menuResetCalibration), "")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        syncMenus()
    }

    /// The camera list is live, so the menu is rebuilt whenever it changes.
    private func rebuildSourceMenu(cameras: [(id: String, name: String)]) {
        guard let sourceMenu else { return }
        sourceMenu.removeAllItems()
        if cameras.isEmpty {
            let empty = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sourceMenu.addItem(empty)
        }
        for (index, camera) in cameras.enumerated() {
            let item = NSMenuItem(title: camera.name, action: #selector(menuCamera(_:)),
                                  keyEquivalent: index < 9 ? String(index + 1) : "")
            item.target = self
            item.representedObject = camera.id
            item.state = (isCameraSource && camera.id == self.camera.currentDeviceID) ? .on : .off
            sourceMenu.addItem(item)
        }
        sourceMenu.addItem(.separator())
        let next = NSMenuItem(title: "Next Camera", action: #selector(menuNextCamera), keyEquivalent: "d")
        next.keyEquivalentModifierMask = []
        next.target = self
        sourceMenu.addItem(next)
        sourceMenu.addItem(.separator())
        let scene = NSMenuItem(title: "Test Scene", action: #selector(menuTestScene), keyEquivalent: "p")
        scene.keyEquivalentModifierMask = []
        scene.target = self
        scene.state = isTestScene ? .on : .off
        sourceMenu.addItem(scene)
        let file = NSMenuItem(title: "Open Video File…", action: #selector(openFile), keyEquivalent: "o")
        file.target = self
        file.state = isFileSource ? .on : .off
        sourceMenu.addItem(file)
    }

    private func syncMenus() {
        let c = renderer.calibration
        toggles["loop"]?.state = renderer.viewport.rectilinear ? .off : .on
        toggles["rect"]?.state = renderer.viewport.rectilinear ? .on : .off
        toggles["raw"]?.state = renderer.rawView ? .on : .off
        toggles["overlay"]?.state = renderer.showOverlay ? .on : .off
        toggles["swap"]?.state = c.swapHalves ? .on : .off
        toggles["front"]?.state = c.mirrorFront ? .on : .off
        toggles["rear"]?.state = c.mirrorRear ? .on : .off
        for (index, item) in sizeItems.enumerated() {
            item.state = ControlBar.outputSizes[index] == renderer.outputSize ? .on : .off
        }
    }

    @objc private func menuZoomIn() { zoom(by: 1.25) }
    @objc private func menuZoomOut() { zoom(by: 0.8) }
    @objc private func menuReset() { resetView() }
    @objc private func menuLoop() { setRectilinear(false) }
    @objc private func menuRectilinear() { setRectilinear(true) }
    @objc private func menuRaw() { setRaw(!renderer.rawView) }
    @objc private func menuOverlay() {
        renderer.showOverlay.toggle()
        syncMenus()
    }
    @objc private func menuSize(_ sender: NSMenuItem) {
        guard ControlBar.outputSizes.indices.contains(sender.tag) else { return }
        setOutputSize(ControlBar.outputSizes[sender.tag])
    }
    @objc private func menuToggleBar() { bar.isHidden.toggle() }
    @objc private func menuCalibration() { showCalibration() }
    @objc private func menuSwap() { mutateCalibration { $0.swapHalves.toggle() } }
    @objc private func menuMirrorFront() { mutateCalibration { $0.mirrorFront.toggle() } }
    @objc private func menuMirrorRear() { mutateCalibration { $0.mirrorRear.toggle() } }
    @objc private func menuResetCalibration() { apply(Calibration()) }
    @objc private func menuCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let device = Camera.availableDevices().first(where: { $0.uniqueID == id }) else { return }
        useCamera(device)
    }
    @objc private func menuNextCamera() {
        camera.cycleDevice()
        if !isCameraSource { useCamera() }
    }
    @objc private func menuTestScene() { useTestScene() }

    // MARK: - Snapshot

    /// `--snapshot`: one output frame to disk, then quit. Verifies the stitch, the viewport
    /// maths and the Syphon surface without anyone at the keyboard.
    private func writeSnapshot(to url: URL) {
        guard let image = renderer.snapshot() else {
            print("snapshot: nothing to render")
            exit(1)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("snapshot: cannot create \(url.path)")
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            print("snapshot: failed to write \(url.path)")
            exit(1)
        }
        let v = renderer.viewport
        let c = renderer.calibration
        print("snapshot \(image.width)x\(image.height) → \(url.path)")
        print(String(format: "source %@ frame %dx%d · %@ zoom %.2f · yaw %+.1f° · pitch %+.1f° · span %.1f°×%.1f°%@",
                     source?.name ?? "none", renderer.frameSize.x, renderer.frameSize.y,
                     v.rectilinear ? "rectilinear" : "loop", v.zoom, v.yaw, v.pitch, v.horizontalSpan, v.verticalSpan,
                     renderer.rawView ? " · raw" : ""))
        print(String(format: "lens %@ fov %.1f° circle (%.0f, %.0f) r (%.0f, %.0f) · blend %.1f° · distance %.2f m · baseline %.3f m · band ±%.1f°%@%@%@",
                     c.projection.rawValue, c.fovDegrees, c.circleCenterX, c.circleCenterY, c.circleRadiusX, c.circleRadiusY,
                     c.blendDegrees, c.stitchDistanceMetres, c.baselineMetres, c.bandHalfPitchDegrees,
                     c.swapHalves ? " · swap" : "", c.mirrorFront ? " · mirror front" : "", c.mirrorRear ? " · mirror rear" : ""))
        if let syphon {
            print("syphon: \(syphon.description[SyphonServerDescriptionNameKey] ?? "?") clients=\(syphon.hasClients)")
        }
        NSApp.terminate(nil)
    }
}

let options = LaunchOptions.parse(CommandLine.arguments)
if options.showHelp {
    print(LaunchOptions.usage)
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
