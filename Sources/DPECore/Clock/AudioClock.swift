import AVFoundation

/// The spine of the whole piece: a sample-accurate, monotonic playback clock.
///
/// Uses AVAudioEngine + AVAudioPlayerNode (not AVAudioPlayer, whose `currentTime`
/// is too coarse and jittery to sync visuals to beats). When no audio file is
/// available it synthesizes a metronome click track at the timeline's BPM so the
/// show is still driven by a real, repeatable sample clock.
final class AudioClock {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var clickBuffer: AVAudioPCMBuffer?
    private var prepared = false
    private var sampleRate: Double = 44_100
    private var baseOffset: Double = 0     // playback start position (for seeking)

    private(set) var usingSynthesizedClick = false
    /// Held mid-playback by `pause()`. Distinct from "stopped": the engine is still
    /// running and the scheduled segment is still loaded, so `resume()` is seamless.
    private(set) var isPaused = false
    /// Total length of the loaded audio (file length, or the synthesized click track).
    private(set) var audioDuration: Double = 0

    /// Output hardware latency — subtract so visuals line up with what's heard.
    var outputLatency: Double { engine.outputNode.presentationLatency }

    /// Master output level, 0…1.
    ///
    /// Applied to the main mixer rather than the player node, so it also governs the
    /// synthesized click track the show falls back to when there is no audio file.
    ///
    /// **Level only — never the clock.** `currentTime()` reads the player node's sample
    /// time, which is unaffected by gain, so muting cannot drift the show. Silencing the
    /// track and letting the visuals run is a legitimate way to rehearse.
    var volume: Float = 1.0 {
        didSet {
            volume = min(1, max(0, volume))
            engine.mainMixerNode.outputVolume = volume
        }
    }

    func prepare(audioURL: URL?, fallbackBPM: Double, fallbackDuration: Double) throws {
        // Tear down any previous run so play/stop/play is clean and repeatable.
        if prepared {
            player.stop()
            engine.stop()
        }
        if player.engine == nil {
            engine.attach(player)
        }

        let format: AVAudioFormat
        if let url = audioURL, let f = try? AVAudioFile(forReading: url) {
            file = f
            clickBuffer = nil
            format = f.processingFormat
            usingSynthesizedClick = false
            audioDuration = format.sampleRate > 0 ? Double(f.length) / format.sampleRate : 0
        } else {
            file = nil
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            clickBuffer = AudioClock.makeClickTrack(bpm: fallbackBPM,
                                                    duration: fallbackDuration,
                                                    format: fmt)
            format = fmt
            usingSynthesizedClick = true
            audioDuration = fallbackDuration
        }
        sampleRate = format.sampleRate

        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Re-apply after the teardown above: prepare() runs again on every play, and a
        // level set before the first show must survive into the next one.
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
        try engine.start()
        prepared = true
    }

    /// Start (or restart) playback from `seconds` into the audio.
    func play(from seconds: Double = 0) {
        guard prepared else { return }
        baseOffset = max(0, seconds)
        schedule(from: baseOffset)
        player.play()
        isPaused = false
    }

    /// Jump to a new position; `playing` keeps the transport running.
    func seek(to seconds: Double, playing: Bool) {
        guard prepared else { return }
        player.stop()                 // resets the node's sampleTime to 0
        baseOffset = max(0, seconds)
        schedule(from: baseOffset)
        if playing { player.play() }
        isPaused = !playing
    }

    /// Hold playback where it is WITHOUT tearing the engine down. `stop()` resets the
    /// node's sampleTime; `pause()` does not, which is exactly what keeps
    /// `currentTime()` continuous across the gap — resume picks up the same sample.
    func pause() {
        guard prepared, !isPaused else { return }
        player.pause()
        isPaused = true
    }

    /// Resume from a `pause()`, or start the segment a `seek(playing: false)` staged.
    func resume() {
        guard prepared, isPaused else { return }
        player.play()
        isPaused = false
    }

    private func schedule(from seconds: Double) {
        if let file = file {
            let startFrame = AVAudioFramePosition(seconds * sampleRate)
            let remaining = file.length - startFrame
            guard remaining > 0 else { return }
            player.scheduleSegment(file, startingFrame: startFrame,
                                   frameCount: AVAudioFrameCount(remaining), at: nil,
                                   completionHandler: nil)
        } else if let buffer = clickBuffer,
                  let segment = AudioClock.slice(buffer, fromFrame: AVAudioFramePosition(seconds * sampleRate)) {
            player.scheduleBuffer(segment, at: nil, options: [], completionHandler: nil)
        }
    }

    func stop() {
        guard prepared else { return }
        player.stop()
        engine.stop()
        prepared = false
        isPaused = false
    }

    /// Absolute playback position in seconds (start offset + rendered time). `nil`
    /// before the first render callback.
    func currentTime() -> Double? {
        // `playerTime(forNodeTime:)` raises an ObjC exception — which Swift cannot catch,
        // so it terminates the process — unless the node time carries a valid sample or
        // host time. `lastRenderTime` returns non-nil with BOTH invalid while the engine
        // is prepared but has never rendered, which is exactly the state a stopped clock
        // is in. Checking the precondition is the only way to ask the question safely.
        guard let nodeTime = player.lastRenderTime,
              nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let pt = player.playerTime(forNodeTime: nodeTime),
              pt.sampleRate > 0 else { return nil }
        return baseOffset + Double(pt.sampleTime) / pt.sampleRate
    }

    /// Copy a PCM buffer from `fromFrame` to the end (for seeking the click track).
    private static func slice(_ buffer: AVAudioPCMBuffer, fromFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let start = max(0, min(Int(fromFrame), Int(buffer.frameLength)))
        let count = Int(buffer.frameLength) - start
        guard count > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(count)
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch] + start, count: count)
        }
        return out
    }

    // MARK: - Synthesized metronome

    private static func makeClickTrack(bpm: Double,
                                       duration: Double,
                                       format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let totalFrames = AVAudioFrameCount(max(1.0, duration) * sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }
        buffer.frameLength = totalFrames
        guard let channels = buffer.floatChannelData else { return buffer }

        let channelCount = Int(format.channelCount)
        let beatInterval = 60.0 / max(1.0, bpm)
        let clickDuration = 0.04
        var beat = 0
        while true {
            let t0 = Double(beat) * beatInterval
            if t0 >= duration { break }
            let start = Int(t0 * sr)
            let length = Int(clickDuration * sr)
            let accent = (beat % 4 == 0)
            let amp: Float = accent ? 0.9 : 0.5
            let freq: Double = accent ? 1_500 : 1_000
            for i in 0..<length {
                let idx = start + i
                if idx >= Int(totalFrames) { break }
                let env = Float(1.0 - Double(i) / Double(length))          // linear decay
                let s = amp * env * Float(sin(2.0 * Double.pi * freq * Double(i) / sr))
                for ch in 0..<channelCount {
                    channels[ch][idx] = s
                }
            }
            beat += 1
        }
        return buffer
    }
}
