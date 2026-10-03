// Owns the link and, in Drone role, the camera + follow controller.
//
// One iPhone, two roles:
//   Remote - phone in your hands: pink sticks, manual flight, tuning, motor test.
//            Used for every test flight with the dummy weight.
//   Drone  - phone mounted on the drone: camera, vision, follow mode.

import SwiftUI
import UIKit

enum AppRole: String {
    case remote, drone
}

final class AppModel: ObservableObject {
    @Published private(set) var role: AppRole?
    @Published var wifiMessage: String?
    @Published var cameraError: String?

    let link = DroneLink()
    let sticks = StickInput()
    private(set) var follow: FollowController?
    private(set) var camera: CameraPipeline?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "role"), let r = AppRole(rawValue: saved) {
            activate(r)
        }
    }

    func activate(_ newRole: AppRole) {
        let link = self.link
        link.stop()
        camera?.stop()
        follow?.stop()
        camera = nil
        follow = nil
        link.telemetryObserver = nil

        switch newRole {
        case .remote:
            let sticks = self.sticks
            link.periodicProvider = { (.rc, sticks.payload().bytes) }
            link.start(as: .remote)

        case .drone:
            let f = FollowController()
            let c = CameraPipeline(follow: f, link: link)
            f.onLandRequest = { [weak link] reason in link?.send(.land, arg: reason.rawValue) }
            c.onError = { [weak self] msg in self?.cameraError = msg }
            link.periodicProvider = { [weak f] in
                guard let f else { return nil }
                return (.follow, f.currentSetpoint().bytes)
            }
            link.telemetryObserver = { [weak f] t in f?.onTelemetry(t) }
            follow = f
            camera = c
            f.start()
            c.start()
            link.start(as: .drone)
        }
        UserDefaults.standard.set(newRole.rawValue, forKey: "role")
        UIApplication.shared.isIdleTimerDisabled = true  // the screen must never lock in flight
        role = newRole
        joinWiFi()
    }

    func leaveRole() {
        link.stop()
        camera?.stop()
        follow?.stop()
        camera = nil
        follow = nil
        UserDefaults.standard.removeObject(forKey: "role")
        role = nil
    }

    func joinWiFi() {
        WiFiJoiner.join { [weak self] message in self?.wifiMessage = message }
    }
}

/// Stick positions, written by the UI and read by the 50 Hz link timer.
final class StickInput {
    private let lock = NSLock()
    private var roll = 0.0, pitch = 0.0, yaw = 0.0, throttle = 0.0

    let deadzone = 0.05   // centred axes only
    let expo = 0.30       // softer around centre, full range at the ends

    func setLeft(yaw: Double, throttle: Double) {
        lock.lock(); self.yaw = yaw; self.throttle = throttle; lock.unlock()
    }

    func setRight(roll: Double, pitch: Double) {
        lock.lock(); self.roll = roll; self.pitch = pitch; lock.unlock()
    }

    private func shape(_ x: Double) -> Double {
        let a = abs(x)
        guard a > deadzone else { return 0 }
        let v = min(1, (a - deadzone) / (1 - deadzone))
        let e = (1 - expo) * v + expo * v * v * v
        return x < 0 ? -e : e
    }

    func payload() -> RcPayload {
        lock.lock()
        let r = roll, p = pitch, y = yaw, t = throttle
        lock.unlock()
        return RcPayload(roll: clampI16(shape(r) * 1000),
                         pitch: clampI16(shape(p) * 1000),
                         yaw: clampI16(shape(y) * 1000),
                         throttle: clampU16(max(0, min(1, t)) * 1000))
    }
}
