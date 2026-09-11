import AVFoundation
import CoreVideo
import Foundation

/// Where segcam's frames come from, in this piece.
///
/// Upstream, segcam takes its pixels from a camera or from a **Syphon** feed — a shared
/// GPU surface published by another app, which means a framework borrowed out of
/// TouchDesigner or OBS at build time. That is a dependency on somebody else's app being
/// installed, and it is the thing this import was asked to do without. What is left is
/// the two sources a show can actually rely on: the machine's own camera, and a video
/// file sitting next to the timeline that names it.
///
/// Both hand over `kCVPixelFormatType_32BGRA` buffers **off the main thread**, which is
/// the contract `SegmentEngine` was written against: it does its work on the queue the
/// frame arrives on and publishes the result to main itself.
protocol SegCamSource: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// A human-readable reason there are no frames, for the view to print instead of
    /// showing black. Nil while it is working.
    var onStatus: ((String?) -> Void)? { get set }
    func start()
    func stop()
    /// Whatever `start()` does that can be done before the cue. Optional: the camera
    /// and the window source have nothing worth doing early.
    func prepare()
}

extension SegCamSource {
    func prepare() {}
}

/// The machine's own camera. Trimmed from segcam's `Camera`: the device cycling, the
/// "devices changed" callback and the name-matching preference existed for its keyboard
/// UI, and a cue has nothing to press.
final class SegCamCamera: NSObject, SegCamSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStatus: ((String?) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dpe.segcam.capture", qos: .userInitiated)
    /// Substring of the device name to prefer, e.g. "FaceTime". Nil takes the default.
    private let deviceHint: String?
    private var started = false

    init(deviceHint: String? = nil) {
        self.deviceHint = deviceHint
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        // The camera grant is asked for at the gate (`Permissions.preflight`), so by the
        // time a cue opens one of these the answer is already in. Asking again here is
        // free when it is granted and silent when it is not.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async { self.onStatus?("no camera access") }
                return
            }
            self.queue.async { self.configureAndRun() }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func configureAndRun() {
        // `.external` is macOS 14; the package targets 13, so on an older system the
        // built-in is discovered and anything plugged in is picked up by the default
        // device below rather than by name.
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified).devices
        let device = deviceHint.flatMap { hint in
            devices.first { $0.localizedName.localizedCaseInsensitiveContains(hint) }
        } ?? devices.first ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            DispatchQueue.main.async { self.onStatus?("no camera found") }
            return
        }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true      // a slow frame is dropped, never queued
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            // Presets are per-device: an iPhone offers a different set to the built-in.
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async { self.onStatus?(nil) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixels)
    }
}

/// A video file, looping. The other half of "camera or file", and the half a show can
/// rehearse against: the same clip segments the same way every take, which a camera
/// pointed at a room never does.
///
/// `AVPlayerItemVideoOutput` rather than `AVAssetReader` because it loops without
/// rebuilding anything and it hands over exactly the pixel format asked for. Frames are
/// pulled on a timer at the file's own rate rather than pushed, so a file that cannot
/// keep up drops frames instead of queueing them — the same behaviour the camera path
/// has with `alwaysDiscardsLateVideoFrames`.
final class SegCamFile: SegCamSource {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStatus: ((String?) -> Void)?

    private let player = AVPlayer()
    private let videoOutput: AVPlayerItemVideoOutput
    private let queue = DispatchQueue(label: "dpe.segcam.file", qos: .userInitiated)
    private var pump: DispatchSourceTimer?
    private let url: URL
    private let hz: Double
    private var looper: Any?
    private var item: AVPlayerItem?

    /// Whether `prepare()` found the file and built the player item.
    var isPrepared: Bool { item != nil }

    init(url: URL, hz: Double = 30) {
        self.url = url
        self.hz = max(1, hz)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
    }

    /// Everything `start()` does that can be done BEFORE the cue: the item, its output,
    /// the loop, and — the part that costs — the player loading the asset and readying
    /// its decoder, which for a 20 Mbps 1080p file is a few hundred milliseconds of
    /// nothing on screen when it happens on the beat. Done at load by
    /// `SegSwarmController.prewarm`, so the cue has only `play()` left. Idempotent; a
    /// missing file prepares nothing, and `start()` reports it the way it always did.
    func prepare() {
        guard item == nil, FileManager.default.fileExists(atPath: url.path) else { return }
        let item = AVPlayerItem(url: url)
        item.add(videoOutput)
        player.replaceCurrentItem(with: item)
        player.isMuted = true                 // the show has its own soundtrack
        player.actionAtItemEnd = .none
        // A local file: start on the frame `play()` is called, never wait to buffer.
        player.automaticallyWaitsToMinimizeStalling = false
        // Loop. A cue outlives the clip and the picture must not stop dead when it does.
        looper = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        self.item = item
    }

    func start() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            onStatus?("no clip at \(url.lastPathComponent)")
            return
        }
        prepare()
        player.play()
        onStatus?(nil)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / hz)
        timer.setEventHandler { [weak self] in self?.pullFrame() }
        timer.resume()
        pump = timer
    }

    func stop() {
        pump?.cancel()
        pump = nil
        player.pause()
        if let looper { NotificationCenter.default.removeObserver(looper) }
        looper = nil
    }

    private func pullFrame() {
        let host = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: host)
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixels = videoOutput.copyPixelBuffer(forItemTime: itemTime,
                                                       itemTimeForDisplay: nil) else { return }
        onFrame?(pixels)
    }

    deinit { stop() }
}
