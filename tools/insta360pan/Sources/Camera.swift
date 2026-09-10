import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// Webcam capture, after ~/segcam's Camera: the same permission flow and live device list,
/// but it chooses the format itself. The Insta360 in webcam mode offers 1920×1080 with the
/// two lenses stacked, and that frame is what the whole app is built around.
final class Camera: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "insta360pan.capture")
    private let output = AVCaptureVideoDataOutput()
    private var configured = false

    /// Readable with `log show --predicate 'subsystem == "com.jamecoyne.insta360pan"'`.
    private static let log = Logger(subsystem: "com.jamecoyne.insta360pan", category: "camera")

    /// Remembered by unique ID, not index: the list changes underfoot when the camera is
    /// plugged in or an iPhone wakes up.
    private(set) var currentDeviceID: String?
    /// True once a camera was picked by hand. Until then the app jumps to an Insta360 the
    /// moment one appears, so plugging it in after launch just works.
    var userChoseDevice = false

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStatus: ((String?) -> Void)?
    /// Called on the main queue when cameras appear, vanish, or the choice changes.
    var onDevicesChanged: (() -> Void)?

    var currentDevice: AVCaptureDevice? {
        Camera.availableDevices().first { $0.uniqueID == currentDeviceID }
    }

    var name: String { currentDevice?.localizedName ?? "no camera" }

    /// Every camera macOS will hand us: built-in, USB, and iPhones over Continuity Camera.
    /// The Insta360 in webcam mode is a USB video device, so it shows up as `.external`.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static func insta360() -> AVCaptureDevice? {
        availableDevices().first { $0.localizedName.lowercased().contains("insta360") }
    }

    /// The Insta360 if it is plugged in, else the first external camera, else anything.
    static func defaultDevice() -> AVCaptureDevice? {
        let devices = availableDevices()
        return insta360()
            ?? devices.first { $0.deviceType == .external }
            ?? devices.first
    }

    override init() {
        super.init()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.devicesChanged(disconnected: note.object as? AVCaptureDevice)
            }
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            onStatus?("Waiting for camera permission…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted
                        ? self.configureAndRun()
                        : self.onStatus?("Camera access denied. Enable it in System Settings › Privacy & Security › Camera.")
                }
            }
        default:
            onStatus?("Camera access denied. Enable it in System Settings › Privacy & Security › Camera.")
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Choosing a camera

    /// Switch to a specific camera. Before the session is configured this only records the
    /// choice; `start` honours it.
    func select(_ device: AVCaptureDevice) {
        currentDeviceID = device.uniqueID
        guard configured else {
            onDevicesChanged?()
            return
        }
        onStatus?("Switching to \(device.localizedName)…")
        queue.async { [weak self] in
            guard let self else { return }
            let ok = swapInput(to: device)
            DispatchQueue.main.async {
                self.onStatus?(ok ? nil : "Could not open \(device.localizedName).")
                self.onDevicesChanged?()
            }
        }
    }

    /// Next camera in the list, starting from whichever one is actually in use.
    func cycleDevice() {
        let devices = Camera.availableDevices()
        guard devices.count > 1 else { return }
        let current = devices.firstIndex { $0.uniqueID == currentDeviceID } ?? 0
        userChoseDevice = true
        select(devices[(current + 1) % devices.count])
    }

    /// Pick the first camera whose name contains `text` (case-insensitive) before the
    /// session starts. Returns false if nothing matched.
    @discardableResult
    func preferDevice(matching text: String) -> Bool {
        let needle = text.lowercased()
        guard let match = Camera.availableDevices().first(where: {
            $0.localizedName.lowercased().contains(needle)
        }) else { return false }
        currentDeviceID = match.uniqueID
        return true
    }

    private func devicesChanged(disconnected: AVCaptureDevice?) {
        let names = Camera.availableDevices().map(\.localizedName).joined(separator: ", ")
        Camera.log.notice("cameras available: \(names, privacy: .public)")
        // If the camera we were using just walked away, fall back to whatever is left
        // rather than sitting on a dead session.
        if let disconnected, disconnected.uniqueID == currentDeviceID,
           let fallback = Camera.defaultDevice() {
            select(fallback)
            return
        }
        // The one we are here for just turned up.
        if configured, !userChoseDevice, let insta = Camera.insta360(), insta.uniqueID != currentDeviceID {
            select(insta)
            return
        }
        onDevicesChanged?()
    }

    // MARK: - Session

    /// 1920×1080 if the camera has it — that is the Insta360's stacked-lens frame — else the
    /// largest frame it offers. Among equals, the fastest.
    private static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func dimensions(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        func area(_ f: AVCaptureDevice.Format) -> Int {
            let d = dimensions(f)
            return Int(d.width) * Int(d.height)
        }
        func rate(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        let formats = device.formats.filter {
            CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video
        }
        let full = formats.filter { dimensions($0).width == 1920 && dimensions($0).height == 1080 }
        if let exact = full.max(by: { rate($0) < rate($1) }) { return exact }
        return formats.max { a, b in
            area(a) != area(b) ? area(a) < area(b) : rate(a) < rate(b)
        }
    }

    /// Capture queue. Returns false if the camera could not be opened.
    private func swapInput(to device: AVCaptureDevice) -> Bool {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        var opened = false
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            opened = true
        }
        session.commitConfiguration()

        guard opened else {
            Camera.log.error("could not open camera \(device.localizedName, privacy: .public)")
            return false
        }
        // After the commit, not inside it: committing re-negotiates the active format. On
        // macOS there is no input-priority preset to ask for; setting the format on a device
        // that is in a session is itself what makes the session follow it.
        if let format = Camera.bestFormat(for: device), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            // 30 fps is what the Insta360 sends; never ask for a rate the format cannot do.
            let wanted = CMTime(value: 1, timescale: 30)
            if format.videoSupportedFrameRateRanges.contains(where: {
                CMTimeCompare(wanted, $0.minFrameDuration) >= 0 && CMTimeCompare(wanted, $0.maxFrameDuration) <= 0
            }) {
                device.activeVideoMinFrameDuration = wanted
            }
            device.unlockForConfiguration()
        }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        Camera.log.notice("using camera \(device.localizedName, privacy: .public) \(d.width)x\(d.height)")
        return true
    }

    private func configureAndRun() {
        let devices = Camera.availableDevices()
        guard let device = devices.first(where: { $0.uniqueID == currentDeviceID }) ?? Camera.defaultDevice() else {
            onStatus?("No camera found.")
            return
        }
        currentDeviceID = device.uniqueID

        if !configured {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true      // slow frames get dropped, never queued
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            configured = true
        }

        queue.async { [weak self] in
            guard let self else { return }
            let ok = swapInput(to: device)
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async {
                self.onStatus?(ok ? nil : "Could not open \(device.localizedName).")
                self.onDevicesChanged?()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixels)
    }
}
