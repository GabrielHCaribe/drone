// Follow-mode settings. Edit here and rebuild (push to GitHub -> TestFlight).
//
// The drone-side safety limits (max tilt 15 deg, max yaw rate, 45 s follow
// timer, failsafe) live on the ESP32 and are tuned from the app's Tune screen.
// Everything below is the phone-side OUTER loop.

import Foundation

enum FollowConfig {
    // ---- what you asked for
    static let targetHeight = 2.0          // m above the take-off point
    static let targetDistance = 4.0        // m, horizontal, drone to you
    static let personHeight = 1.80         // m (5'11"). Refined by "Calibrate 3 m" in Drone mode.

    // ---- lost-target behaviour: hover 3 s -> slow yaw search 20 s -> land
    static let lostHoverSeconds = 3.0
    static let searchSeconds = 20.0
    static let searchYawRate = 20.0        // deg/s
    static let lostAfterSeconds = 0.5      // target unseen this long = lost
    static let acquireSeconds = 2.0        // after take-off, look this long before searching

    // ---- take-off / height
    static let climbRate = 0.5             // m/s
    static let maxHeight = 3.5             // m, setpoint is never above this
    static let hardMaxHeight = 4.5         // m, above this the phone commands a landing
    static let heightKp = 0.10             // throttle per m
    static let heightKi = 0.04             // throttle per (m*s)
    static let heightKd = 0.12             // throttle per (m/s)
    static let heightIntegralLimit = 0.15
    static let throttleRange = 0.20        // +- around hover throttle
    static let spoolUpSeconds = 1.0        // hover feed-forward ramps in over this time

    // ---- horizontal (distance -> pitch, sideways offset -> roll)
    static let distanceKp = 4.0            // deg per m
    static let distanceKd = 3.0            // deg per (m/s)
    static let lateralKp = 4.0             // deg per m
    static let lateralKd = 3.0             // deg per (m/s)
    static let maxTilt = 12.0              // deg (ESP32 also clamps to its own max_angle_follow)
    static let distanceDeadband = 0.3      // m

    // ---- camera
    static let useFrontCamera = true       // false = rear ultra-wide (flip the phone in the mount)
    /// If the drone slides AWAY from you sideways during the hand-held check in
    /// docs/TESTING.md, the image is mirrored on your phone: set this to true.
    static let invertLateral = false

    // ---- yaw
    /// Heading stays locked while following (agreed behaviour). Setting this
    /// above 0 adds a gentle turn toward you when you are near the frame edge.
    static let yawAssistGain = 0.0         // deg/s per deg of bearing beyond 20 deg
}
