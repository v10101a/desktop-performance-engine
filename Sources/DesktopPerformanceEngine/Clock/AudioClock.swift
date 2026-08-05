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

    private(set) var usingSynthesizedClick = false

    /// Output hardware latency — subtract so visuals line up with what's heard.
    var outputLatency: Double { engine.outputNode.presentationLatency }

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
        } else {
            file = nil
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            clickBuffer = AudioClock.makeClickTrack(bpm: fallbackBPM,
                                                    duration: fallbackDuration,
                                                    format: fmt)
            format = fmt
            usingSynthesizedClick = true
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        prepared = true
    }

    func play() {
        guard prepared else { return }
        if let file = file {
            player.scheduleFile(file, at: nil, completionHandler: nil)
        } else if let buffer = clickBuffer {
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }
        player.play()
    }

    func stop() {
        guard prepared else { return }
        player.stop()
        engine.stop()
        prepared = false
    }

    /// Seconds since playback started, derived from the render clock. `nil` before
    /// the first render callback. Always starts near 0 for take-to-take repeatability.
    func currentTime() -> Double? {
        guard let nodeTime = player.lastRenderTime,
              let pt = player.playerTime(forNodeTime: nodeTime),
              pt.sampleRate > 0 else { return nil }
        return Double(pt.sampleTime) / pt.sampleRate
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
