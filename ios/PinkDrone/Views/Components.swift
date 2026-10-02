import SwiftUI

/// Big, unmistakable emergency stop. Fires on touch-DOWN (no waiting for release).
struct KillButton: View {
    @ObservedObject var link: DroneLink
    var size: CGFloat = 120
    @State private var fired = false

    var body: some View {
        let latched = link.killLatched
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.45, blue: 0.56), Color(red: 0.83, green: 0.06, blue: 0.27)],
                                     center: .init(x: 0.5, y: 0.3), startRadius: 2, endRadius: size * 0.7))
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 4).padding(5))
                .overlay(Circle().stroke(Theme.danger, lineWidth: 3))
                .shadow(color: Theme.danger.opacity(latched ? 1 : 0.7), radius: latched ? 28 : 16)
            VStack(spacing: 2) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: size * 0.22, weight: .black))
                Text("KILL").font(.system(size: size * 0.2, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .scaleEffect(fired ? 0.92 : 1)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !fired {
                    fired = true
                    link.kill()
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
            .onEnded { _ in fired = false })
        .accessibilityLabel("Emergency kill")
    }
}

/// Press and hold to confirm (used for Disarm while flying).
struct HoldButton: View {
    let title: String
    var seconds: Double = 0.8
    var tint: LinearGradient = .secondaryCandy
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                ZStack(alignment: .leading) {
                    Capsule().fill(tint)
                    GeometryReader { g in
                        Capsule().fill(Theme.pink.opacity(0.6)).frame(width: g.size.width * progress)
                    }
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
            )
            .shadow(color: Theme.pink.opacity(0.4), radius: 8)
            .onLongPressGesture(minimumDuration: seconds, pressing: { pressing in
                holding = pressing
                withAnimation(pressing ? .linear(duration: seconds) : .easeOut(duration: 0.2)) { progress = pressing ? 1 : 0 }
            }, perform: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                action()
                withAnimation { progress = 0 }
            })
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9).shadow(color: color, radius: 4)
    }
}

/// Battery, link, mode, altitude, armed. Overlaid at the top of both roles.
struct TelemetryBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var link: DroneLink
    var height: Double? = nil

    var body: some View {
        let t = link.telemetry
        HStack(spacing: 8) {
            pill {
                StatusDot(color: link.connected ? Theme.ok : Theme.danger)
                Text(link.connected ? "Drone" : "No drone").bold()
            }
            if let t, link.connected {
                pill {
                    StatusDot(color: t.laptopConnected ? Theme.ok : Theme.danger)
                    Text(t.laptopConnected ? "Kill switch" : "No laptop")
                }
                pill {
                    Image(systemName: batteryIcon(t))
                    Text(t.batteryPresent ? String(format: "%.1f V", t.vbat) : "USB")
                }
                .foregroundStyle(t.batteryWarn ? Theme.danger : Theme.text)
                pill { Text(t.state.label).bold() }
                    .foregroundStyle(t.state == .killed || t.state == .imuFault ? Theme.danger : Theme.softPink)
                if let h = height {
                    pill { Image(systemName: "arrow.up.and.down"); Text(String(format: "%.1f m", h)) }
                }
                pill { Text(t.armed ? "ARMED" : "SAFE").bold() }
                    .foregroundStyle(t.armed ? Theme.warn : Theme.ok)
                if t.state == .follow {
                    pill { Image(systemName: "timer"); Text(String(format: "%.0f s", t.followLeft)) }
                }
                let loss = model.role == .drone ? t.linkLoss[2] : t.linkLoss[1]
                if loss > 0 { pill { Text("loss \(loss)%") }.foregroundStyle(loss > 5 ? Theme.danger : Theme.warn) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.text)
    }

    private func batteryIcon(_ t: Telemetry) -> String {
        guard t.batteryPresent else { return "powerplug" }
        let perCell = t.vbat / 3
        if perCell > 3.95 { return "battery.100" }
        if perCell > 3.75 { return "battery.75" }
        if perCell > 3.6 { return "battery.50" }
        return "battery.25"
    }

    @ViewBuilder private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.panel.opacity(0.85)).overlay(Capsule().stroke(Theme.pink.opacity(0.3), lineWidth: 1)))
    }
}

/// Shows the latest command result (e.g. why arming was refused).
struct AckToast: View {
    @ObservedObject var link: DroneLink
    @State private var visible = false

    var body: some View {
        Group {
            if visible, let ack = link.lastAck, let cmd = ack.command {
                Text(ack.result == .ok ? "\(cmd.label) ✓" : "\(cmd.label): \(ack.result.label)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(ack.result == .ok ? Theme.ok : Theme.warn)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.panel.opacity(0.95)))
                    .shadow(color: Theme.pink.opacity(0.4), radius: 8)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .onChange(of: link.lastAck?.time) { _, _ in
            withAnimation { visible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { visible = false } }
        }
    }
}

struct WiFiBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let msg = model.wifiMessage {
            HStack {
                Image(systemName: "wifi.exclamationmark")
                Text(msg).lineLimit(2)
                Button("Retry") { model.joinWiFi() }.buttonStyle(CandyButtonStyle(compact: true)).frame(width: 80)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.warn)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel.opacity(0.95)))
        }
    }
}
