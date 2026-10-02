// Turns pixel positions into real-world angles using the phone's own gravity
// vector. Because the phone is rigidly mounted, its attitude IS the camera's
// attitude, so this also compensates for the drone pitching and rolling
// (requirement: "compensate for camera tilt") with no ESP32 round trip.
//
// Distance and height without LiDAR (you standing on flat ground, height H):
//
//      camera  *  ---------------------------- horizon
//              |  \ \   angle to head  = a_h (below horizon)
//      height  |   \  \  angle to feet = a_f
//         h    |    \    \
//              |     \  head  \
//      ground  +------ you (H) ---feet
//                  <------ d ------>
//
//   tan(a_f) = h / d        tan(a_h) = (h - H) / d
//   =>  d = H / (tan a_f - tan a_h)      h = d * tan a_f

import Foundation
import simd
import CoreGraphics

struct CameraIntrinsics {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var width: Double
    var height: Double

    /// From the horizontal field of view reported by AVFoundation.
    init(width: Int, height: Int, horizontalFOVDegrees: Double) {
        self.width = Double(width)
        self.height = Double(height)
        let longSide = Double(max(width, height))
        fx = (longSide / 2) / tan(horizontalFOVDegrees * .pi / 360)
        fy = fx
        cx = self.width / 2
        cy = self.height / 2
    }
}

struct CameraGeometry {
    /// `gravity`: CoreMotion gravity in the device frame (points to the ground).
    /// `front`: front (selfie) camera looks along +z of the device frame, rear along -z.
    /// The image is assumed upright (horizon-level rotation) and NOT mirrored.
    let gravity: SIMD3<Double>
    let front: Bool
    let intrinsics: CameraIntrinsics

    private var g: SIMD3<Double> { simd_normalize(gravity) }

    private var axes: (right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        let gv = g
        let down: SIMD3<Double> = abs(gv.x) > abs(gv.y) ? SIMD3(gv.x > 0 ? 1 : -1, 0, 0) : SIMD3(0, gv.y > 0 ? 1 : -1, 0)
        let forward: SIMD3<Double> = front ? SIMD3(0, 0, 1) : SIMD3(0, 0, -1)
        let right = simd_cross(down, forward)
        return (right, down, forward)
    }

    /// Unit ray for a point in normalized image coordinates (0..1, origin top-left).
    func ray(nx: Double, ny: Double) -> SIMD3<Double> {
        let a = axes
        let x = (nx * intrinsics.width - intrinsics.cx) / intrinsics.fx
        let y = (ny * intrinsics.height - intrinsics.cy) / intrinsics.fy
        return simd_normalize(a.right * x + a.down * y + a.forward)
    }

    /// Angle below the horizon (radians, + = below).
    func depression(nx: Double, ny: Double) -> Double {
        asin(max(-1, min(1, simd_dot(ray(nx: nx, ny: ny), g))))
    }

    /// Horizontal bearing relative to where the camera points (radians, + = right).
    func bearing(nx: Double, ny: Double) -> Double {
        let gv = g
        let r = ray(nx: nx, ny: ny)
        let a = axes
        func horiz(_ v: SIMD3<Double>) -> SIMD3<Double> { v - simd_dot(v, gv) * gv }
        let fh = horiz(a.forward), rh = horiz(a.right), vh = horiz(r)
        guard simd_length(fh) > 1e-3, simd_length(rh) > 1e-3 else { return 0 }
        return atan2(simd_dot(vh, simd_normalize(rh)), simd_dot(vh, simd_normalize(fh)))
    }
}

struct PersonMeasurement {
    var distance: Double?        // m, horizontal
    var cameraHeight: Double?    // m above your feet
    var bearing: Double          // rad, + = you are to the right
    var lateral: Double?         // m, + = you are to the right
}

enum PersonGeometry {
    /// `box`: normalized, origin top-left. Feet = bottom edge centre, head = top edge centre.
    static func measure(box: CGRect, geometry: CameraGeometry, personHeight: Double, heightEstimate: Double?) -> PersonMeasurement {
        let cx = Double(box.midX)
        let feetVisible = box.maxY < 0.97
        let headVisible = box.minY > 0.03
        let bearing = geometry.bearing(nx: cx, ny: Double(box.midY))
        var m = PersonMeasurement(distance: nil, cameraHeight: nil, bearing: bearing, lateral: nil)

        let af = geometry.depression(nx: cx, ny: Double(box.maxY))
        if feetVisible && headVisible {
            let ah = geometry.depression(nx: cx, ny: Double(box.minY))
            let denom = tan(af) - tan(ah)
            if denom > 0.05 {
                let d = personHeight / denom
                if d > 0.5 && d < 25 {
                    m.distance = d
                    m.cameraHeight = d * tan(af)
                }
            }
        } else if feetVisible, let h = heightEstimate, h > 0.5, af > 0.05 {
            // Head cut off: use the feet angle and the fused height estimate.
            let d = h / tan(af)
            if d > 0.5 && d < 25 { m.distance = d }
        }
        if let d = m.distance { m.lateral = d * tan(bearing) }
        return m
    }

    /// Calibration: you stand exactly `distance` metres away. Returns the
    /// effective person height that makes the geometry match (absorbs how loose
    /// Vision's bounding box is around you).
    static func calibratePersonHeight(box: CGRect, geometry: CameraGeometry, distance: Double) -> Double? {
        let cx = Double(box.midX)
        guard box.maxY < 0.97, box.minY > 0.03 else { return nil }
        let af = geometry.depression(nx: cx, ny: Double(box.maxY))
        let ah = geometry.depression(nx: cx, ny: Double(box.minY))
        let h = distance * (tan(af) - tan(ah))
        return (h > 1.0 && h < 2.6) ? h : nil
    }
}
