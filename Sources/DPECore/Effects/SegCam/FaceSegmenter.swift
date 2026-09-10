//  Imported from ~/segcam (2026-09-10), unchanged except for this header.
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
import Vision

/// Vision-backed segmenter: the face's parts, the face itself, and the body — each one a
/// segment only if the settings ask for it (eyes and mouth by default).
///
/// Nothing is tracked between frames. Every frame's face is a new instance, so `eye.L#412`,
/// `eye.R#412`, `mouth#412` and `face#412` are one face in one frame and the next frame gets
/// fresh numbers. Bodies are numbered on their own.
final class FaceSegmenter {
    private let sequence = VNSequenceRequestHandler()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let bodyRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false          // whatever of the person is in the frame
        return request
    }()
    private let numberer = InstanceNumberer()
    private let maxFaces = 4
    private let maxBodies = 4

    func reset() { numberer.reset() }

    func segments(in frame: Frame, settings: SegmentSettings) -> [Segment] {
        guard let buffer = frame.pixelBuffer else { return [] }
        // Only the requests something is switched on for — a body pass is a second model.
        var requests: [VNRequest] = []
        if settings.detectFace || settings.detectEyes || settings.detectMouth { requests.append(faceRequest) }
        if settings.detectBody { requests.append(bodyRequest) }
        guard !requests.isEmpty else { return [] }
        do {
            try sequence.perform(requests, on: buffer, orientation: .up)
        } catch {
            return []
        }
        let faces = requests.contains(faceRequest) ? (faceRequest.results ?? []) : []
        let bodies = requests.contains(bodyRequest) ? (bodyRequest.results ?? []) : []
        return build(faces: faces, bodies: bodies,
                     imageSize: CGSize(width: frame.width, height: frame.height), settings: settings)
    }

    /// Split out from `segments(in:)` so the CLI harness can drive it from a still image.
    func build(faces: [VNFaceObservation], imageSize: CGSize) -> [Segment] {
        build(faces: faces, bodies: [], imageSize: imageSize, settings: SegmentSettings())
    }

    func build(faces: [VNFaceObservation], bodies: [VNHumanObservation], imageSize: CGSize,
               settings: SegmentSettings) -> [Segment] {
        var out: [Segment] = []
        for face in faces.prefix(maxFaces) {
            let number = numberer.take()
            if settings.detectFace {
                // The observation's box is already normalized, bottom-left: flipped once.
                out.append(Segment(id: SegmentID(kind: .face, number: number),
                                   rect: NormRect.fromVision(face.boundingBox).padded(by: 0.05),
                                   score: face.confidence))
            }
            guard let landmarks = face.landmarks else { continue }

            // Landmark points hug the lid and lip line, so an unpadded box reads as too tight.
            if settings.detectEyes, let region = landmarks.leftEye {
                out.append(Segment(id: SegmentID(kind: .eyeLeft, number: number),
                                   rect: box(region, imageSize: imageSize).padded(by: 0.4).atLeast(0.02),
                                   score: face.confidence))
            }
            if settings.detectEyes, let region = landmarks.rightEye {
                out.append(Segment(id: SegmentID(kind: .eyeRight, number: number),
                                   rect: box(region, imageSize: imageSize).padded(by: 0.4).atLeast(0.02),
                                   score: face.confidence))
            }
            if settings.detectMouth, let region = landmarks.outerLips {
                out.append(Segment(id: SegmentID(kind: .mouth, number: number),
                                   rect: box(region, imageSize: imageSize).padded(by: 0.15).atLeast(0.03),
                                   score: face.confidence))
            }
        }
        if settings.detectBody {
            for body in bodies.prefix(maxBodies) {
                out.append(Segment(id: SegmentID(kind: .body, number: numberer.take()),
                                   rect: NormRect.fromVision(body.boundingBox),
                                   score: body.confidence))
            }
        }
        return out
    }

    /// Vision landmark points are image-space, origin bottom-left — flipped here, once.
    private func box(_ region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> NormRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let points = region.pointsInImage(imageSize: imageSize).map {
            CGPoint(x: $0.x / imageSize.width, y: 1 - $0.y / imageSize.height)
        }
        return NormRect.bounding(points).clamped()
    }
}
