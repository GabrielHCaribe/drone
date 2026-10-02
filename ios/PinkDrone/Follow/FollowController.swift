// =============================================================================
//  OUTER LOOPS (iPhone, Drone role).  See firmware/DroneFC/flight.cpp for the
//  inner loops on the ESP32 and the reasoning behind the split.
//
//  Runs here because only the phone has the camera, the barometer and the
//  person tracker. These loops are slow (1-2 Hz bandwidth), so 30-100 Hz on the
//  phone plus ~10-30 ms WiFi latency is plenty. The ESP32 clamps every
//  setpoint to its own limits and lands on its own if these packets stop.
//
//      phone:  you (vision)  ->  distance  -> pitch setpoint
//                            ->  sideways  -> roll setpoint
//              height (KF)   ->  height    -> throttle
//      ESP32:  angle setpoints -> angle loop -> rate loop -> motors (1 kHz)
//
//  Phases: IDLE -> TAKEOFF -> ACQUIRE -> TRACK <-> LOST_HOVER -> SEARCH -> (land)
// =============================================================================

import Foundation
import CoreMotion
import CoreGraphics
import simd

final class FollowStatus: ObservableObject {
    @Published var phase: FollowPhase = .idle
    @Published var tracking = false
    @Published var distance: Double?
    @Published var bearingDeg: Double?
    @Published var lateral: Double?
    @Published var height = 0.0
    @Published var heightSigma = 0.0
    @Published var sensorsReady = false
    @Published var barometerAvailable = true
    @Published var targetBox: CGRect?
    @Published var otherBoxes: [CGRect] = []
    @Published var personHeight = FollowConfig.personHeight
}

final class FollowController {
    let status = FollowStatus()
    let tracker = PersonTracker()
    let front = FollowConfig.useFrontCamera

    /// Sends CMD_LAND with the given reason (wired to the DroneLink by AppModel).
    var onLandRequest: ((LandReason) -> Void)?

    private let queue = DispatchQueue(label: "pinkdrone.follow", qos: .userInteractive)
    private let motionQueue = OperationQueue()
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let kf = HeightEstimator()

    // sensors
    private var gravity = SIMD3<Double>(0, -1, 0)
    private var lastMotionTimestamp: TimeInterval?
    private var lastMotionWall: TimeInterval = 0
    private var intrinsics: CameraIntrinsics?
    private var lastFrameTime: TimeInterval = 0
    private var cameraHeightOffset = 0.15     // camera height above your feet while the drone sits on the ground
    private var lastGroundUpdate: TimeInterval = 0

    // drone state (from telemetry)
    private var espState: FlightState = .disarmed
    private var hoverThrottle = 0.5

    // phase machine
    private var phase: FollowPhase = .idle
    private var phaseStart: TimeInterval = 0
    private var followStart: TimeInterval = 0
    private var heightSetpoint = 0.0
    private var heightIntegral = 0.0
    private var lastLandRequest: TimeInterval = 0
    private var groundResetDone = false

    // target
    private var targetBox: CGRect?
    private var otherBoxes: [CGRect] = []
    private var lastTargetTime: TimeInterval = 0
    private var distFilt: Double?
    private var distRate = 0.0
    private var latFilt: Double?
    private var latRate = 0.0
    private var lastMeasTime: TimeInterval = 0
    private var bearing = 0.0
    private var personHeight: Double

    // output
    private let spLock = NSLock()
    private var setpointUnsafe = FollowSetpoint()
    private let boxLock = NSLock()
    private var targetBoxUnsafe: CGRect?
    private var lastStatusPublish: TimeInterval = 0

    init() {
        let saved = UserDefaults.standard.double(forKey: "personHeight")
        personHeight = (saved > 1.0 && saved < 2.6) ? saved : FollowConfig.personHeight
        status.personHeight = personHeight
        motionQueue.underlyingQueue = queue
        motionQueue.maxConcurrentOperationCount = 1
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - lifecycle

    func start() {
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.01
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] m, _ in
                guard let self, let m else { return }
                self.onMotion(m)
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let data else { return }
                self.kf.updateBarometer(relativeAltitude: data.relativeAltitude.doubleValue)
            }
        } else {
            DispatchQueue.main.async { self.status.barometerAvailable = false }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }

    // MARK: - inputs (any thread)

    func setIntrinsics(_ k: CameraIntrinsics) {
        queue.async { self.intrinsics = k }
    }

    func onTelemetry(_ t: Telemetry) {
        queue.async {
            self.espState = t.state
            if t.hoverThrottle > 0.15 { self.hoverThrottle = t.hoverThrottle }
        }
    }

    func onVision(_ boxes: [PersonBox], time: TimeInterval) {
        queue.async { self.handleVision(boxes, time: time) }
    }

    /// Latest locked target box (normalized, top-left origin) for overlays and video.
    var currentTargetBox: CGRect? {
        boxLock.lock(); defer { boxLock.unlock() }
        return targetBoxUnsafe
    }

    /// Thread-safe: called by the link timer at 50 Hz.
    func currentSetpoint() -> FollowSetpoint {
        spLock.lock(); defer { spLock.unlock() }
        return setpointUnsafe
    }

    /// Stand exactly `distance` m in front of the drone (drone on the ground), then call.
    func calibratePersonHeight(distance: Double, completion: @escaping (Double?) -> Void) {
        queue.async {
            var result: Double?
            if let box = self.targetBox, let k = self.intrinsics, self.now - self.lastTargetTime < 0.5 {
                let geo = CameraGeometry(gravity: self.gravity, front: self.front, intrinsics: k)
                result = PersonGeometry.calibratePersonHeight(box: box, geometry: geo, distance: distance)
            }
            if let h = result {
                self.personHeight = h
                UserDefaults.standard.set(h, forKey: "personHeight")
            }
            DispatchQueue.main.async {
                if let h = result { self.status.personHeight = h }
                completion(result)
            }
        }
    }

    // MARK: - sensor handling (follow queue)

    private func onMotion(_ m: CMDeviceMotion) {
        let g = SIMD3<Double>(m.gravity.x, m.gravity.y, m.gravity.z)
        if simd_length(g) > 0.5 { gravity = g }
        let gu = simd_normalize(gravity)
        let ua = SIMD3<Double>(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z)
        let accelUp = -simd_dot(ua, gu) * 9.81
        if let last = lastMotionTimestamp {
            kf.predict(accelUp: accelUp, dt: m.timestamp - last)
        }
        lastMotionTimestamp = m.timestamp
        lastMotionWall = now
        step()
    }

    private func handleVision(_ boxes: [PersonBox], time: TimeInterval) {
        lastFrameTime = time
        var target: CGRect?
        if phase == .idle {
            // On the ground: show whoever is closest (also used for calibration).
            if tracker.lockClosest(boxes, now: time) { target = tracker.locked }
        } else {
            target = tracker.update(boxes, now: time)
            if target == nil, [.acquire, .lostHover, .search].contains(phase), tracker.lockClosest(boxes, now: time) {
                target = tracker.locked
            }
        }
        targetBox = target
        otherBoxes = boxes.map { $0.rect }.filter { $0 != target }
        boxLock.lock(); targetBoxUnsafe = target; boxLock.unlock()

        guard let box = target, let k = intrinsics else { return }
        lastTargetTime = time
        let geo = CameraGeometry(gravity: gravity, front: front, intrinsics: k)
        let airborne = phase != .idle && phase != .landing
        let m = PersonGeometry.measure(box: box, geometry: geo, personHeight: personHeight,
                                       heightEstimate: airborne ? kf.height + cameraHeightOffset : nil)
        bearing = FollowConfig.invertLateral ? -m.bearing : m.bearing

        if let ch = m.cameraHeight, let d = m.distance {
            if airborne {
                kf.updateVision(height: ch - cameraHeightOffset, distance: d)
            } else if phase == .idle, ch > 0, ch < 0.6 {
                cameraHeightOffset += 0.05 * (ch - cameraHeightOffset)  // learn the mount height on the ground
            }
        }

        let dt = max(time - lastMeasTime, 1.0 / 60)
        let fresh = time - lastMeasTime < 0.3
        lastMeasTime = time
        if let d = m.distance {
            if let prev = distFilt, fresh {
                let nf = prev + 0.35 * (d - prev)
                distRate += 0.3 * ((nf - prev) / dt - distRate)
                distFilt = nf
            } else {
                distFilt = d
                distRate = 0
            }
        }
        let latMeasured = (m.lateral ?? (FollowConfig.targetDistance * tan(m.bearing))) * (FollowConfig.invertLateral ? -1 : 1)
        if let prev = latFilt, fresh {
            let nf = prev + 0.35 * (latMeasured - prev)
            latRate += 0.3 * ((nf - prev) / dt - latRate)
            latFilt = nf
        } else {
            latFilt = latMeasured
            latRate = 0
        }
    }

    // MARK: - control step (100 Hz, follow queue)

    private func enter(_ p: FollowPhase) {
        phase = p
        phaseStart = now
    }

    private func step() {
        let t = now
        let dt = 0.01

        switch espState {
        case .follow:
            if phase == .idle {
                followStart = t
                heightSetpoint = 0
                heightIntegral = 0
                tracker.unlock()
                distFilt = nil
                latFilt = nil
                enter(.takeoff)
            }
            runPhases(t: t, dt: dt)
        case .landing, .failsafeHover:
            if phase != .idle { phase = .landing }
        default:
            if phase != .idle { enter(.idle) }
            if espState == .followCountdown {
                if !groundResetDone {
                    kf.resetOnGround(baro: kf.latestBarometer)
                    groundResetDone = true
                }
            } else {
                groundResetDone = false
            }
            if t - lastGroundUpdate > 0.1 {
                lastGroundUpdate = t
                kf.updateOnGround()
            }
        }

        var sp = FollowSetpoint()
        sp.phase = phase
        sp.heightM = kf.height
        sp.vzMps = kf.velocity
        let visible = t - lastTargetTime < 0.3
        let sensorsReady = lastMotionTimestamp != nil && intrinsics != nil && t - lastFrameTime < 0.5
        var flags: UInt8 = 0
        if sensorsReady { flags |= FollowFlags.ready }
        if visible && phase != .idle { flags |= FollowFlags.tracking }
        if lastMotionTimestamp != nil { flags |= FollowFlags.heightValid }

        // .landing is included: until the ESP32 switches to LANDING we keep holding height
        // and level instead of letting the setpoints go inactive.
        let flying = espState == .follow && [.takeoff, .acquire, .track, .lostHover, .search, .landing].contains(phase)
        if flying {
            flags |= FollowFlags.active
            sp.throttle = heightLoop(t: t, dt: dt)
            if phase == .track, visible {
                if let d = distFilt {
                    var e = d - FollowConfig.targetDistance
                    if abs(e) < FollowConfig.distanceDeadband { e = 0 }
                    sp.pitchDeg = clamp(-(FollowConfig.distanceKp * e + FollowConfig.distanceKd * distRate), FollowConfig.maxTilt)
                }
                if let y = latFilt {
                    sp.rollDeg = clamp(FollowConfig.lateralKp * y + FollowConfig.lateralKd * latRate, FollowConfig.maxTilt)
                }
                let bDeg = bearing * 180 / .pi
                if FollowConfig.yawAssistGain > 0, abs(bDeg) > 20 {
                    sp.yawRateDps = FollowConfig.yawAssistGain * (bDeg - (bDeg > 0 ? 20 : -20))
                }
            }
            if phase == .search { sp.yawRateDps = FollowConfig.searchYawRate }
        }
        sp.flags = flags
        spLock.lock(); setpointUnsafe = sp; spLock.unlock()

        if t - lastStatusPublish > 0.1 {
            lastStatusPublish = t
            publishStatus(visible: visible, sensorsReady: sensorsReady)
        }
    }

    private func runPhases(t: TimeInterval, dt: Double) {
        let visible = t - lastTargetTime < 0.3
        let inPhase = t - phaseStart

        // Safety: never climb away.
        if kf.height > FollowConfig.hardMaxHeight { requestLand(.command, t: t); return }

        switch phase {
        case .takeoff:
            heightSetpoint = min(FollowConfig.targetHeight, heightSetpoint + FollowConfig.climbRate * dt)
            if kf.height > FollowConfig.targetHeight - 0.25 && inPhase > 2 { enter(.acquire) }
        case .acquire:
            if visible { enter(.track) } else if inPhase > FollowConfig.acquireSeconds { enter(.search) }
        case .track:
            if t - lastTargetTime > FollowConfig.lostAfterSeconds { enter(.lostHover) }
        case .lostHover:
            if visible { enter(.track) } else if inPhase > FollowConfig.lostHoverSeconds { enter(.search) }
        case .search:
            if visible { enter(.track) } else if inPhase > FollowConfig.searchSeconds { requestLand(.targetLost, t: t) }
        case .landing:
            // The ESP32 is still in FOLLOW: our land command was lost, repeat it.
            if t - lastLandRequest > 0.5 { requestLand(.targetLost, t: t) }
        case .idle:
            break
        }
        heightSetpoint = min(heightSetpoint, FollowConfig.maxHeight)
    }

    private func requestLand(_ reason: LandReason, t: TimeInterval) {
        lastLandRequest = t
        if phase != .landing { phase = .landing; phaseStart = t }
        let cb = onLandRequest
        DispatchQueue.main.async { cb?(reason) }
    }

    private func heightLoop(t: TimeInterval, dt: Double) -> Double {
        let sinceStart = t - followStart
        let spool = min(1, sinceStart / FollowConfig.spoolUpSeconds)
        let e = heightSetpoint - kf.height
        if sinceStart > FollowConfig.spoolUpSeconds {
            heightIntegral += FollowConfig.heightKi * e * dt
            heightIntegral = max(-FollowConfig.heightIntegralLimit, min(FollowConfig.heightIntegralLimit, heightIntegral))
        }
        var thr = hoverThrottle * spool + FollowConfig.heightKp * e + heightIntegral - FollowConfig.heightKd * kf.velocity
        let upper = hoverThrottle + FollowConfig.throttleRange
        let lower = spool < 1 ? 0.0 : hoverThrottle - FollowConfig.throttleRange
        thr = max(lower, min(upper, thr))
        return thr
    }

    private func clamp(_ x: Double, _ limit: Double) -> Double { max(-limit, min(limit, x)) }

    private func publishStatus(visible: Bool, sensorsReady: Bool) {
        let phase = self.phase, h = kf.height, hs = kf.heightSigma
        let d = visible ? distFilt : nil
        let b = visible ? bearing * 180 / .pi : nil
        let lat = visible ? latFilt : nil
        let box = targetBox, others = otherBoxes
        DispatchQueue.main.async {
            let s = self.status
            if s.phase != phase { s.phase = phase }
            s.tracking = visible
            s.distance = d
            s.bearingDeg = b
            s.lateral = lat
            s.height = h
            s.heightSigma = hs
            s.sensorsReady = sensorsReady
            s.targetBox = box
            s.otherBoxes = others
        }
    }
}
