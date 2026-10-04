// Remote role: the phone is in your hands (all test flights, manual flying).
//
//   [ telemetry: link | kill switch | battery | mode | armed ]
//   [ left stick ]   [ horizon / status / ARM LAND ]   [ right stick ]
//   [ menu ]               [ KILL ]                     [ tune | motors ]

import SwiftUI

struct RemoteView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var link: DroneLink
    @State private var showTuning = false
    @State private var showMotorTest = false
    @State private var showFollowInfo = false

    var body: some View {
        let t = link.telemetry
        let armed = t?.armed ?? false
        VStack(spacing: 6) {
            HStack {
                TelemetryBar(link: link)
                Menu {
                    Button("Switch to Drone role") { model.activate(.drone) }
                    Button("Re-join drone WiFi") { model.joinWiFi() }
                    Button("Choose role…") { model.leaveRole() }
                    Button("Switch look") { model.toggleLook() }.disabled(!model.canSwitchLook)
                } label: {
                    Image(systemName: "ellipsis.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.softPink)
                }
            }
            WiFiBanner()

            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 4) {
                    StickView(kind: .throttleYaw) { x, y in model.sticks.setLeft(yaw: x, throttle: y) }
                    Text("Throttle · Yaw").font(.system(size: 11, weight: .semibold, design: Theme.fontDesign)).foregroundStyle(Theme.muted)
                }

                VStack(spacing: 10) {
                    ZStack {
                        AttitudeView(roll: t?.roll ?? 0, pitch: t?.pitch ?? 0)
                        AckToast(link: link).offset(y: 70)
                    }
                    .frame(maxHeight: 150)

                    if let t, !armed, t.state == .disarmed, t.armBlockManual != .ok {
                        Text("Arm: \(t.armBlockManual.label)")
                            .font(.system(size: 12, weight: .semibold, design: Theme.fontDesign)).foregroundStyle(Theme.warn)
                    } else if let t {
                        Text(t.state == .manual ? "Manual · thr \(Int(t.throttle * 100))%" : (t.lastEvent == .noEvent ? t.state.label : "\(t.state.label) · \(t.lastEvent.label)"))
                            .font(.system(size: 12, weight: .semibold, design: Theme.fontDesign)).foregroundStyle(Theme.softPink)
                    }

                    HStack(spacing: 10) {
                        if armed {
                            HoldButton(title: "Hold: Disarm") { link.disarm() }
                        } else {
                            Button(link.killLatched || t?.state == .killed ? "Reset kill" : "Arm") {
                                if link.killLatched || t?.state == .killed { link.disarm() } else { link.send(.arm) }
                            }
                            .buttonStyle(CandyButtonStyle(tint: .mintCandy, glow: Theme.ok))
                        }
                        Button("Land") { link.send(.land) }.buttonStyle(CandyButtonStyle(tint: .lilacCandy, glow: Theme.lilac))
                    }
                    HStack(spacing: 10) {
                        Button("Manual") { link.send(.arm) }
                            .buttonStyle(CandyButtonStyle(tint: t?.state == .manual ? Theme.candy : .secondaryCandy, compact: true))
                            .disabled(armed)
                        Button("Follow") { showFollowInfo = true }.buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true))
                    }
                }
                .frame(maxWidth: 260)

                VStack(spacing: 4) {
                    StickView(kind: .pitchRoll) { x, y in model.sticks.setRight(roll: x, pitch: y) }
                    Text("Pitch · Roll").font(.system(size: 11, weight: .semibold, design: Theme.fontDesign)).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(alignment: .bottom) {
                Button { showTuning = true } label: { Label("Tune", systemImage: "slider.horizontal.3") }
                    .buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true)).frame(width: 110)
                Spacer()
                KillButton(link: link, size: 84)
                Spacer()
                Button { showMotorTest = true } label: { Label("Motors", systemImage: "fanblades.fill") }
                    .buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true)).frame(width: 110)
                    .disabled(armed)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .sheet(isPresented: $showTuning) { TuningView(link: link) }
        .sheet(isPresented: $showMotorTest) { MotorTestView(link: link) }
        .alert("Follow mode", isPresented: $showFollowInfo) {
            Button("Switch to Drone role") { model.activate(.drone) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Follow mode runs on the phone mounted on the drone. Switch this phone to the Drone role, mount it, then press Follow (or Start Follow on the laptop).")
        }
    }
}
