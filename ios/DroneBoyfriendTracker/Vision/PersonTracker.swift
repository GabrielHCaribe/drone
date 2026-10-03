// Person detection (Apple Vision, full-body rectangles) + lock-on tracking.
//
// Lock-on rule (as agreed): lock the CLOSEST person = the tallest box, then
// follow only that person by matching each new frame's boxes to the locked one
// (overlap first, then nearest centre). Vision runs on every camera frame; on
// the A15 a full-body detection at 640x480 takes a few milliseconds.

import Foundation
import Vision
import CoreVideo
import CoreGraphics

struct PersonBox {
    let rect: CGRect      // normalized, origin TOP-left, y down
    let confidence: Float
}

final class PersonTracker {
    private let request: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false  // full body: we need the feet for distance/height
        return r
    }()

    private(set) var locked: CGRect?
    private(set) var lastSeen: TimeInterval = 0
    private let minConfidence: Float = 0.4

    /// Runs Vision on one frame. Call on the camera queue.
    func detect(_ pixelBuffer: CVPixelBuffer) -> [PersonBox] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let results = request.results ?? []
        return results.compactMap { obs in
            guard obs.confidence >= minConfidence else { return nil }
            let b = obs.boundingBox  // origin bottom-left
            return PersonBox(rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), confidence: obs.confidence)
        }
    }

    /// Lock onto the closest (tallest) person. Returns false if nobody is visible.
    @discardableResult
    func lockClosest(_ boxes: [PersonBox], now: TimeInterval) -> Bool {
        guard let best = boxes.max(by: { $0.rect.height < $1.rect.height }) else { return false }
        locked = best.rect
        lastSeen = now
        return true
    }

    func unlock() { locked = nil }

    /// Associates this frame's detections with the locked target.
    /// Returns the target's box if it is visible in this frame.
    func update(_ boxes: [PersonBox], now: TimeInterval) -> CGRect? {
        guard let prev = locked, !boxes.isEmpty else { return nil }
        var best: PersonBox?
        var bestScore = -Double.infinity
        for b in boxes {
            let iou = PersonTracker.iou(prev, b.rect)
            let dx = Double(prev.midX - b.rect.midX), dy = Double(prev.midY - b.rect.midY)
            let centreDist = (dx * dx + dy * dy).squareRoot()
            let sizeRatio = Double(b.rect.height / max(prev.height, 0.01))
            // Reject jumps that are too large to be the same person between frames.
            let maxJump = 0.35 + 0.5 * min(now - lastSeen, 1.0)
            guard centreDist < maxJump, sizeRatio > 0.5, sizeRatio < 2.0 else { continue }
            let score = iou * 2 - centreDist
            if score > bestScore { bestScore = score; best = b }
        }
        guard let match = best else { return nil }
        locked = match.rect
        lastSeen = now
        return match.rect
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        if i.isNull || i.isEmpty { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }
}
