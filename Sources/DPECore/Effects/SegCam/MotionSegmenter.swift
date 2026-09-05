//  Imported from ~/segcam (2026-09-03), unchanged except for this header.
//
//  segcam is a standalone macOS app: real-time webcam segmentation shown as green boxes
//  over the video, or as a desktop full of windows. This is its ENGINE — the part with no
//  opinion about where the pixels come from or what is done with the answer — carried in
//  whole so the two stay comparable. What was left behind: the Syphon input (a dependency
//  on a framework borrowed from TouchDesigner or OBS, and the thing the piece explicitly
//  does not want), the HUD and its slider, the keyboard handling, the device-cycling, the
//  desktop swarm, and the app scaffolding around all of it.
//
//  Fixes belong upstream first. If this file and ~/segcam's copy drift, the one there is
//  the original.

import CoreGraphics
import Foundation

/// Segments things that are moving: a slowly adapting background model, a difference
/// threshold, then morphology to turn a spray of changed cells into solid objects.
final class MotionSegmenter {
    private var background: [Float] = []
    private var gridWidth = 0
    private var gridHeight = 0
    private let numberer = InstanceNumberer()

    func reset() {
        background.removeAll()
        gridWidth = 0
        gridHeight = 0
        numberer.reset()
    }

    func segments(in frame: Frame, settings: SegmentSettings) -> [Segment] {
        let grid = frame.luma
        guard grid.count > 0 else { return [] }

        if gridWidth != grid.width || gridHeight != grid.height || background.count != grid.count {
            gridWidth = grid.width
            gridHeight = grid.height
            background = grid.pixels.map(Float.init)
            return []                                   // first frame is only a reference
        }

        let tau = Float(max(1, settings.motionSensitivity))
        let alpha = max(0.001, min(0.5, settings.motionAdaptation))
        var mask = [UInt8](repeating: 0, count: grid.count)
        for i in 0..<grid.count {
            let value = Float(grid.pixels[i])
            if abs(value - background[i]) > tau { mask[i] = 1 }
            background[i] += (value - background[i]) * alpha
        }

        // One erode kills sensor speckle, two dilates glue an object back together
        // (a moving arm shows up as changed *edges*, not a filled shape).
        mask = ConnectedComponents.erode(mask, width: grid.width, height: grid.height)
        mask = ConnectedComponents.dilate(mask, width: grid.width, height: grid.height)
        mask = ConnectedComponents.dilate(mask, width: grid.width, height: grid.height)

        let minPixels = max(4, Int(settings.minAreaFraction * CGFloat(grid.count)))
        let blobs = ConnectedComponents.label(mask: mask, width: grid.width, height: grid.height,
                                              minPixels: minPixels, maxCount: settings.maxSegments)
        return blobs.map { blob in
            Segment(id: SegmentID(kind: .motion, number: numberer.take()),
                    rect: blob.box,
                    score: Float(blob.pixels) / Float(grid.count))
        }
    }
}
