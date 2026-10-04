// PROPS-OFF motor test and ESC calibration.
// The ESP32 caps motor-test output at 15 % and stops the motors 0.5 s after
// this screen stops sending.

import SwiftUI

struct MotorTestView: View {
    @ObservedObject var link: DroneLink
    @Environment(\.dismiss) private var dismiss
    @State private var propsOff = false
    @State private var values: [Double] = [0, 0, 0, 0]
    @State private var escStep = 0  // 0 idle, 1 high sent, 2 low sent
    @State private var confirmEsc = false

    private let names = ["M1 rear-right (CW)", "M2 front-right (CCW)", "M3 rear-left (CCW)", "M4 front-left (CW)"]

    var body: some View {
        NavigationStack {
            ZStack {
                PinkBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        GlassCard {
                            Toggle(isOn: $propsOff) {
                                Label("All four propellers are REMOVED", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 15, weight: .bold, design: Theme.fontDesign))
                                    .foregroundStyle(propsOff ? Theme.ok : Theme.warn)
                            }
                            .tint(Theme.pink)
                        }

                        HStack(alignment: .top, spacing: 16) {
                            quadDiagram.frame(width: 170, height: 170)
                            VStack(spacing: 10) {
                                ForEach(0..<4, id: \.self) { i in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(names[i])  \(Int(values[i] * 100))%")
                                            .font(.system(size: 12, weight: .semibold, design: Theme.fontDesign)).foregroundStyle(Theme.text)
                                        Slider(value: Binding(get: { values[i] }, set: { values[i] = $0; push() }), in: 0...0.15)
                                    }
                                }
                                HStack {
                                    Button("Stop all") { values = [0, 0, 0, 0]; push() }
                                        .buttonStyle(CandyButtonStyle(tint: .lilacCandy, compact: true))
                                    Button("All 8%") { values = [0.08, 0.08, 0.08, 0.08]; push() }
                                        .buttonStyle(CandyButtonStyle(tint: .secondaryCandy, compact: true))
                                }
                            }
                            .disabled(!propsOff)
                            .opacity(propsOff ? 1 : 0.4)
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("ESC calibration (props OFF, see docs/TESTING.md)")
                                    .font(.system(size: 14, weight: .bold, design: Theme.fontDesign)).foregroundStyle(Theme.softPink)
                                Text("1. Flight battery UNPLUGGED, ESP32 on USB, phone connected.\n2. Press \"Max signal\".\n3. Plug in the flight battery, wait for the ESC beeps.\n4. Press \"Min signal\", wait for the confirmation beeps.\n5. Press \"Finish\".")
                                    .font(.system(size: 12, design: Theme.fontDesign)).foregroundStyle(Theme.text)
                                HStack {
                                    Button("Max signal") { confirmEsc = true }
                                        .buttonStyle(CandyButtonStyle(tint: escStep == 1 ? Theme.candy : .secondaryCandy, compact: true))
                                    Button("Min signal") { link.send(.escCalLow); escStep = 2 }
                                        .buttonStyle(CandyButtonStyle(tint: escStep == 2 ? Theme.candy : .secondaryCandy, compact: true))
                                        .disabled(escStep == 0)
                                    Button("Finish") { link.send(.escCalExit); escStep = 0 }
                                        .buttonStyle(CandyButtonStyle(tint: .mintCandy, compact: true))
                                }
                                .disabled(!propsOff)
                            }
                        }
                        AckToast(link: link)
                    }
                    .padding()
                }
            }
            .navigationTitle("Motor test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Send FULL throttle signal?", isPresented: $confirmEsc) {
                Button("Yes, props are off", role: .destructive) { link.send(.escCalHigh); escStep = 1 }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If the flight battery is connected and props are on, the motors will go to full power.")
            }
        }
        .tint(Theme.pink)
        .onChange(of: propsOff) { _, on in if !on { values = [0, 0, 0, 0] }; push() }
        .onDisappear {
            link.setMotorTest(nil)
            if escStep != 0 { link.send(.escCalExit) }
        }
    }

    private func push() {
        guard propsOff else { link.setMotorTest(nil); return }
        link.setMotorTest(values.map { UInt16(max(0, min(150, $0 * 1000))) })
    }

    /// Top view, front up, Betaflight numbering.
    private var quadDiagram: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let pos: [CGPoint] = [CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.2, y: 0.2)]
            let cw = [true, false, false, true]
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0.2 * s, y: 0.2 * s)); p.addLine(to: CGPoint(x: 0.8 * s, y: 0.8 * s))
                    p.move(to: CGPoint(x: 0.8 * s, y: 0.2 * s)); p.addLine(to: CGPoint(x: 0.2 * s, y: 0.8 * s))
                }
                .stroke(Theme.softPink.opacity(0.6), lineWidth: 5)
                Text("FRONT").font(.system(size: 10, weight: .bold, design: Theme.fontDesign)).foregroundStyle(Theme.muted).position(x: s / 2, y: 8)
                ForEach(0..<4, id: \.self) { i in
                    ZStack {
                        Circle().fill(Theme.dreamy.opacity(0.3 + values[i] * 4))
                        Circle().stroke(Theme.pink, lineWidth: 2)
                        VStack(spacing: 0) {
                            Text("M\(i + 1)").font(.system(size: 13, weight: .heavy, design: Theme.fontDesign))
                            Image(systemName: cw[i] ? "arrow.clockwise" : "arrow.counterclockwise").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Theme.text)
                    }
                    .frame(width: s * 0.3, height: s * 0.3)
                    .glow(color: Theme.pink.opacity(values[i] > 0 ? 0.9 : 0.2), radius: 10)
                    .position(x: pos[i].x * s, y: pos[i].y * s)
                }
            }
        }
    }
}
