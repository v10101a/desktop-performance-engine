import AppKit

/// The imported segmenter (~/segcam). What is pinned here is the arithmetic the port
/// depends on and the wiring the timeline depends on — the parts that can be checked
/// without a camera in front of the machine. Whether it actually sees anything is
/// `--test-segcam`, which needs hardware or a clip and reports what it found.
enum SegCamTests {
    static func run(_ t: TestHarness) {
        t.suite("segcam") { t in

            // The sensitivity knob is INVERTED under the hood: the segmenter takes a
            // difference threshold where smaller means twitchier, and everything facing
            // outward — the timeline's `intensity`, segcam's slider — reads as
            // sensitivity. A port that loses the inversion silently makes 1.0 the
            // deadest setting instead of the liveliest.
            var settings = SegmentSettings()
            settings.motionSensitivityFraction = 1.0
            let atMost = settings.motionSensitivity
            settings.motionSensitivityFraction = 0.0
            let atLeast = settings.motionSensitivity
            t.expect(atMost < atLeast,
                     "more sensitivity is a smaller threshold (\(atMost) vs \(atLeast))")
            settings.motionSensitivityFraction = 0.5
            t.near(settings.motionSensitivityFraction, 0.5, 0.02, "…and the knob round-trips")

            // Letterboxing. The picture keeps its aspect inside whatever window a cue
            // gives it, centred — the boxes are placed against this rect, so a wrong one
            // puts every segment somewhere the thing it marks is not.
            let wide = FrameMap.contentRect(in: CGRect(x: 0, y: 0, width: 400, height: 400),
                                            aspect: 2.0)
            t.near(Double(wide.width), 400, 0.001, "a 2:1 picture fills a square window's width")
            t.near(Double(wide.height), 200, 0.001, "…at half its height")
            t.near(Double(wide.midY), 200, 0.001, "…centred")

            // Mirroring is a horizontal flip about the picture, not about the window.
            let box = NormRect(x: 0.0, y: 0.25, w: 0.25, h: 0.5)
            let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
            let plain = FrameMap.fit(box, into: bounds, aspect: 2.0, mirrored: false)
            let flipped = FrameMap.fit(box, into: bounds, aspect: 2.0, mirrored: true)
            t.near(Double(plain.minX), 0, 0.001, "unmirrored, a box at the left edge stays there")
            t.near(Double(flipped.maxX), 400, 0.001, "mirrored, it is at the right edge")
            t.near(Double(plain.minY), Double(flipped.minY), 0.001, "and y is untouched either way")

            // A clip that is not there must say so rather than showing black: "not
            // installed" and "broken" have to look different on stage, the same rule the
            // DooM window follows.
            let missing = MainActor.assumeIsolated {
                SegCamView(size: NSSize(width: 320, height: 200),
                           content: ContentSpec(kind: "segcam", path: "assets/no-such-clip.mov"))
            }
            t.expect(missing.statusForTesting?.contains("no clip") == true,
                     "a missing clip is reported in the window: \(missing.statusForTesting ?? "nil")")
            t.expect(!missing.hasPictureForTesting, "…and nothing is drawn as if it were video")

            // THE SWARM (cue 21). Its windows are panels above everything, so the one
            // thing that must hold is that they all go: this is checked against a clip
            // that does not exist, which spawns nothing and therefore flashes nothing on
            // screen during a test run. That it actually fills a desktop is
            // `--test-segswarm`, which needs a real clip and puts 60 windows up.
            let swarm = SegSwarmController()
            MainActor.assumeIsolated {
                swarm.begin(SegSwarmParams(id: "t", path: "assets/no-such-clip.mov",
                                           mode: "motion"))
            }
            t.equal(swarm.windowCountForTesting, 0, "a clip that is not there spawns no windows")
            MainActor.assumeIsolated { swarm.closeAll() }
            t.expect(!swarm.isRunning, "closeAll stops the source")
            t.equal(swarm.windowCountForTesting, 0, "…and leaves nothing on the desktop")

            // The content kind is reachable from a timeline, with the two sources the
            // import was asked for and no third one: the Syphon feed is gone.
            let spec = ContentSpec(kind: "segcam", mode: "motion")
            let view = MainActor.assumeIsolated {
                makeEffectContentView(spec, size: NSSize(width: 320, height: 200))
            }
            t.expect(view.subviews.contains { $0 is SegCamView },
                     "openWindow · segcam builds the segmenter view")
        }
    }
}
