// Drone role: the phone is mounted on the drone, screen facing you.
// Live camera fills the centre; controls sit on the left and right edges.
// The buttons are for use ON THE GROUND (you can't reach the phone in flight;
// in the air your kill switch is the laptop).

import SwiftUI
import AVFoundation

struct CameraView: UIViewRepresentable {
    let pipeline: CameraPipeline
    let mirrored: Bool

    func makeUIView(context: Context) -> SampleBufferUIView {
        let v = SampleBufferUIView()
        v.displayLayer.videoGravity = .resizeAspect
        v.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        v.backgroundColor = .black
        pipeline.setDisplayLayer(v.displayLayer)
        return v
    }

    func updateUIView(_ uiView: SampleBufferUIView, context: Context) {}
}

struct DroneView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var link: DroneLink
    let follow: FollowController
    @ObservedObject var status: FollowStatus
    let camera: CameraPipeline
    @State private var calibMessage: String?

    var body: some View {
        let t = link.telemetry
        let state = t?.state ?? .boot
        HStack(spacing: 10) {
            // ---------------- left edge
            VStack(spacing: 10) {
                if state == .followCountdown {
                    Button("Cancel") { link.send(.cancelFollow) }
                        .buttonStyle(CandyButtonStyle(tint: .lilacCandy, glow: Theme.lilac))
                } else {
                    Button {
                        link.send(.startFollow)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "figure.walk.motion").font(.system(size: 26, weight: .bold))
                            Text("Follow").font(.system(size: 17, weight: .heavy, design: .rounded))
                        }
                    }
                    .buttonStyle(CandyButtonStyle())
                    .disabled(state != .disarmed)
                }
                Button("Land") { link.send(.land) }
                    .buttonStyle(CandyButtonStyle(tint: .lilacCandy, glow: Theme.lilac))
                Button("Manual") {}
                    .buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true))
                    .disabled(true)
                    .overlay(Text("Remote role").font(.system(size: 9, design: .rounded)).foregroundStyle(Theme.muted).offset(y: 22))
                Spacer()
                readiness
                Menu {
                    Button("Calibrate distance (stand exactly 3 m away)") {
                        follow.calibratePersonHeight(distance: 3) { h in
                            calibMessage = h.map { String(format: "Calibrated: you measure %.2f m", $0) } ?? "Calibration failed: be fully in frame, 3 m away"
                        }
                    }
                    Button("Switch to Remote role") { model.activate(.remote) }
                    Button("Re-join drone WiFi") { model.joinWiFi() }
                    Button("Choose role…") { model.leaveRole() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle.fill")
                }
                .buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true))
            }
            .frame(width: 130)

            // ---------------- centre: camera
            ZStack {
                CameraView(pipeline: camera, mirrored: follow.front)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay(boxesOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.dreamy, lineWidth: 3))
                    .shadow(color: Theme.pink.opacity(0.45), radius: 14)

                VStack {
                    TelemetryBar(link: link, height: status.height)
                    WiFiBanner()
                    if let msg = model.cameraError ?? calibMessage {
                        Text(msg).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.warn)
                            .padding(6).background(Capsule().fill(Theme.panel.opacity(0.9)))
                    }
                    Spacer()
                    AckToast(link: link)
                    infoLine(t)
                }
                .padding(8)

                if state == .followCountdown, let t {
                    Text("\(max(1, Int(ceil(t.countdown))))")
                        .font(.system(size: 150, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.dreamy)
                        .shadow(color: Theme.pink, radius: 24)
                        .transition(.scale)
                }
            }

            // ---------------- right edge
            VStack(spacing: 14) {
                KillButton(link: link, size: 118)
                if t?.armed == true {
                    HoldButton(title: "Hold: Disarm") { link.disarm() }
                } else if link.killLatched || state == .killed {
                    Button("Reset kill") { link.disarm() }.buttonStyle(CandyButtonStyle(tint: .mintCandy, glow: Theme.ok))
                }
                Spacer()
            }
            .frame(width: 130)
        }
        .padding(10)
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(status.sensorsReady, "Sensors")
            row(status.barometerAvailable, "Barometer")
            row(link.telemetry?.laptopConnected ?? false, "Laptop")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.text)
    }

    private func row(_ ok: Bool, _ text: String) -> some View {
        HStack(spacing: 6) { StatusDot(color: ok ? Theme.ok : Theme.danger); Text(text) }
    }

    @ViewBuilder private func infoLine(_ t: Telemetry?) -> some View {
        let phase = status.phase
        HStack(spacing: 8) {
            Text(phase == .idle ? (t?.state == .disarmed && t?.armBlockFollow != .ok ? "Follow: \(t?.armBlockFollow.label ?? "")" : "Ready") : phase.label)
                .bold()
            if let d = status.distance { Text(String(format: "%.1f m away", d)) }
            if let b = status.bearingDeg { Text(String(format: "%.0f° to drone's %@", abs(b), b >= 0 ? "right" : "left")) }
            if phase == .idle, let vh = status.visionHeight { Text(String(format: "cam %.1f m up", vh)) }
            if let e = t?.lastEvent, e != .noEvent, phase == .idle { Text("· \(e.label)").foregroundStyle(Theme.muted) }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Theme.panel.opacity(0.85)))
    }

    /// Person boxes drawn in the same (mirrored) space as the video.
    private var boxesOverlay: some View {
        GeometryReader { g in
            let mirror = follow.front
            ZStack(alignment: .topLeading) {
                ForEach(Array(status.otherBoxes.enumerated()), id: \.offset) { _, r in
                    box(r, in: g.size, mirror: mirror).stroke(Theme.lilac.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                }
                if let r = status.targetBox {
                    box(r, in: g.size, mirror: mirror)
                        .stroke(Theme.pink, lineWidth: 4)
                        .shadow(color: Theme.pink, radius: 8)
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Theme.pink)
                        .position(x: (mirror ? 1 - r.midX : r.midX) * g.size.width, y: max(10, r.minY * g.size.height - 12))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func box(_ r: CGRect, in size: CGSize, mirror: Bool) -> Path {
        let x = mirror ? 1 - r.maxX : r.minX
        return Path(roundedRect: CGRect(x: x * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height),
                    cornerRadius: 14)
    }
}
