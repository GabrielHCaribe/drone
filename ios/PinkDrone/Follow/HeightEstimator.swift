// Height above the take-off point, fused from everything the iPhone has:
//   * accelerometer (CoreMotion user acceleration, 100 Hz)  -> prediction
//   * barometer (CMAltimeter relative altitude)              -> slow correction
//   * vision (camera height from your feet/head angles)     -> absolute correction
//   * "on the ground" constraint before take-off
//
// 3-state Kalman filter: x = [height, vertical speed, barometer bias].
// The bias state absorbs the barometer offset caused by prop wash, which the
// vision measurement makes observable.

import Foundation

final class HeightEstimator {
    private(set) var height = 0.0
    private(set) var velocity = 0.0
    private var bias = 0.0
    private var P: [[Double]] = [[0.01, 0, 0], [0, 0.01, 0], [0, 0, 1]]
    private var lastBaro: Double?
    private var rejectStreak = 0

    // noise
    private let accelSigma = 0.8         // m/s^2 (vibration)
    private let biasWalk = 0.05          // m/sqrt(s)
    private let baroSigma = 0.35         // m
    private let groundSigma = 0.02       // m

    var heightSigma: Double { sqrt(max(P[0][0], 0)) }

    /// Before take-off: everything zero, current barometer reading = ground.
    func resetOnGround(baro: Double?) {
        height = 0
        velocity = 0
        bias = baro ?? 0
        P = [[1e-4, 0, 0], [0, 1e-4, 0], [0, 0, 0.01]]
        rejectStreak = 0
    }

    func predict(accelUp: Double, dt: Double) {
        guard dt > 0, dt < 0.1 else { return }
        height += velocity * dt + 0.5 * accelUp * dt * dt
        velocity += accelUp * dt
        // P = F P F' + Q, F = [[1,dt,0],[0,1,0],[0,0,1]]
        let p = P
        var n = p
        n[0][0] = p[0][0] + dt * (p[1][0] + p[0][1]) + dt * dt * p[1][1]
        n[0][1] = p[0][1] + dt * p[1][1]
        n[1][0] = n[0][1]
        n[0][2] = p[0][2] + dt * p[1][2]
        n[2][0] = n[0][2]
        n[1][1] = p[1][1]
        n[1][2] = p[1][2]
        n[2][1] = n[1][2]
        n[2][2] = p[2][2]
        let q = accelSigma * accelSigma
        n[0][0] += 0.25 * dt * dt * dt * dt * q
        n[0][1] += 0.5 * dt * dt * dt * q
        n[1][0] += 0.5 * dt * dt * dt * q
        n[1][1] += dt * dt * q
        n[2][2] += biasWalk * biasWalk * dt
        P = n
    }

    /// Generic scalar update: z = H x + noise.
    @discardableResult
    private func update(z: Double, H: [Double], sigma: Double, gate: Double? = nil) -> Bool {
        let x = [height, velocity, bias]
        let predicted = H[0] * x[0] + H[1] * x[1] + H[2] * x[2]
        let innov = z - predicted
        var PH = [0.0, 0.0, 0.0]
        for i in 0..<3 { PH[i] = P[i][0] * H[0] + P[i][1] * H[1] + P[i][2] * H[2] }
        let S = H[0] * PH[0] + H[1] * PH[1] + H[2] * PH[2] + sigma * sigma
        if let g = gate, abs(innov) > g * sqrt(S) { return false }
        let K = PH.map { $0 / S }
        height += K[0] * innov
        velocity += K[1] * innov
        bias += K[2] * innov
        var n = P
        for i in 0..<3 { for j in 0..<3 { n[i][j] = P[i][j] - K[i] * PH[j] } }
        P = n
        return true
    }

    func updateBarometer(relativeAltitude: Double) {
        lastBaro = relativeAltitude
        update(z: relativeAltitude, H: [1, 0, 1], sigma: baroSigma)
    }

    /// Vision height with a 3-sigma gate. Many rejections in a row means the
    /// filter has drifted, so the next measurement is accepted anyway.
    func updateVision(height z: Double, distance: Double) {
        let sigma = 0.10 + 0.04 * distance
        if update(z: z, H: [1, 0, 0], sigma: sigma, gate: rejectStreak > 15 ? nil : 3.0) {
            rejectStreak = 0
        } else {
            rejectStreak += 1
        }
    }

    func updateOnGround() {
        update(z: 0, H: [1, 0, 0], sigma: groundSigma)
        update(z: 0, H: [0, 1, 0], sigma: 0.05)
    }

    var latestBarometer: Double? { lastBaro }
}
