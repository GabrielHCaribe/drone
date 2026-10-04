// Pink, cute on-screen sticks with real RC behaviour (Mode 2):
//   left  = throttle (up/down, STAYS where you leave it, like a real throttle
//           stick) + yaw (left/right, springs back to centre)
//   right = pitch + roll (both spring back to centre)
//
// Touches are handled in UIKit (one touch per stick, true multi-touch, no
// gesture-recognizer delay). Movement is RELATIVE to where your thumb lands, so
// touching the top of the left pad never jumps the throttle to full.
// Deadzone + expo are applied when the packet is built (StickInput.payload()).

import SwiftUI
import UIKit

final class TouchPadView: UIView {
    var began: ((CGPoint) -> Void)?
    var moved: ((CGPoint) -> Void)?
    var ended: (() -> Void)?
    private weak var activeTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let t = touches.first else { return }
        activeTouch = t
        began?(t.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        moved?(t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        guard let t = activeTouch, touches.contains(t) else { return }
        activeTouch = nil
        ended?()
    }
}

struct TouchPad: UIViewRepresentable {
    var began: (CGPoint) -> Void
    var moved: (CGPoint) -> Void
    var ended: () -> Void

    func makeUIView(context: Context) -> TouchPadView { TouchPadView(frame: .zero) }

    func updateUIView(_ view: TouchPadView, context: Context) {
        view.began = began
        view.moved = moved
        view.ended = ended
    }
}

struct StickView: View {
    enum Kind { case throttleYaw, pitchRoll }

    let kind: Kind
    /// (x, y): x = -1..1 (right +). y = throttle 0..1, or pitch -1..1 (forward/up +).
    let onChange: (Double, Double) -> Void

    @State private var x = 0.0
    @State private var y = 0.0
    @State private var startX = 0.0
    @State private var startY = 0.0
    @State private var startPoint = CGPoint.zero
    @State private var touching = false

    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let knob = side * 0.34
            let travel = side / 2 - knob / 2 - 6
            let yDisplay = kind == .throttleYaw ? (y * 2 - 1) : y

            ZStack {
                if Theme.basic {
                    Circle().fill(Color(white: 0.12)).overlay(Circle().stroke(Color(white: 0.35), lineWidth: 1))
                    Rectangle().fill(Color(white: 0.3)).frame(width: 1, height: side * 0.8)
                    Rectangle().fill(Color(white: 0.3)).frame(width: side * 0.8, height: 1)
                } else {
                    // pad
                    RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.panel, Theme.plumLight.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                        .overlay(
                            RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                                .stroke(LinearGradient(colors: [Theme.softPink.opacity(0.8), Theme.lilac.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
                        )
                        .glow(color: Theme.pink.opacity(touching ? 0.55 : 0.25), radius: touching ? 18 : 10)

                    // soft crosshair
                    Capsule().fill(Theme.softPink.opacity(0.18)).frame(width: 3, height: side * 0.7)
                    Capsule().fill(Theme.softPink.opacity(0.18)).frame(width: side * 0.7, height: 3)
                    ForEach(0..<4) { i in
                        Image(systemName: "heart.fill")
                            .font(.system(size: side * 0.06))
                            .foregroundStyle(Theme.softPink.opacity(0.35))
                            .offset(x: [0, travel + knob * 0.32, 0, -(travel + knob * 0.32)][i],
                                    y: [-(travel + knob * 0.32), 0, travel + knob * 0.32, 0][i])
                    }
                }

                // throttle level bar
                if kind == .throttleYaw {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Theme.plum.opacity(0.8))
                        Capsule().fill(Theme.dreamy).frame(height: max(6, (side * 0.62) * y))
                    }
                    .frame(width: 7, height: side * 0.62)
                    .offset(x: -side / 2 + 12)
                }

                // knob
                ZStack {
                    if Theme.basic {
                        Circle().fill(Color(white: touching ? 0.75 : 0.6))
                    } else {
                        Circle().fill(Theme.dreamy)
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.7), .clear], center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: knob * 0.45))
                        Circle().stroke(.white.opacity(0.85), lineWidth: 2)
                        Image(systemName: "heart.fill")
                            .font(.system(size: knob * 0.36, weight: .bold))
                            .foregroundStyle(Theme.pink)
                            .glow(color: .white.opacity(0.6), radius: 2)
                    }
                }
                .frame(width: knob, height: knob)
                .glow(color: Theme.pink.opacity(touching ? 0.95 : 0.6), radius: touching ? 16 : 9)
                .scaleEffect(touching && !Theme.basic ? 1.06 : 1)
                .offset(x: x * travel, y: -yDisplay * travel)
            }
            .frame(width: side, height: side)
            .position(x: g.size.width / 2, y: g.size.height / 2)
            .overlay(
                TouchPad(
                    began: { p in
                        startPoint = p
                        startX = x
                        startY = y
                        withAnimation(.easeOut(duration: 0.12)) { touching = true }
                        haptic.impactOccurred(intensity: 0.6)
                    },
                    moved: { p in
                        let dx = Double((p.x - startPoint.x) / travel)
                        let dy = Double((p.y - startPoint.y) / travel)
                        x = max(-1, min(1, startX + dx))
                        if kind == .throttleYaw {
                            let ny = max(0, min(1, startY - dy / 2))
                            if ny == 0 && y > 0 { haptic.impactOccurred(intensity: 0.4) }
                            y = ny
                        } else {
                            y = max(-1, min(1, startY - dy))
                        }
                        onChange(x, y)
                    },
                    ended: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) {
                            touching = false
                            x = 0
                            if kind == .pitchRoll { y = 0 }
                        }
                        onChange(0, kind == .pitchRoll ? 0 : y)
                    })
            )
        }
    }
}

/// Cute artificial horizon for the Remote role.
struct AttitudeView: View {
    let roll: Double
    let pitch: Double

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                if Theme.basic {
                    Circle().fill(Color(red: 0.3, green: 0.55, blue: 0.85))
                    Rectangle()
                        .fill(Color(red: 0.5, green: 0.35, blue: 0.2))
                        .frame(width: s * 2, height: s)
                        .offset(y: s / 2 + CGFloat(pitch) * s / 90)
                        .rotationEffect(.degrees(-roll))
                        .clipShape(Circle())
                    Rectangle().fill(.yellow).frame(width: s * 0.36, height: 2)
                    Circle().stroke(Color(white: 0.4), lineWidth: 1)
                } else {
                    Circle().fill(LinearGradient(colors: [Theme.lilac.opacity(0.55), Theme.softPink.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    Rectangle()
                        .fill(LinearGradient(colors: [Theme.pink.opacity(0.75), Theme.plumLight], startPoint: .top, endPoint: .bottom))
                        .frame(width: s * 2, height: s)
                        .offset(y: s / 2 + CGFloat(pitch) * s / 90)
                        .rotationEffect(.degrees(-roll))
                        .clipShape(Circle())
                    Capsule().fill(.white).frame(width: s * 0.36, height: 4).glow(color: Theme.pink, radius: 4)
                    Circle().fill(.white).frame(width: 9, height: 9)
                    Circle().stroke(Theme.softPink, lineWidth: 3)
                }
            }
            .frame(width: s, height: s)
            .position(x: g.size.width / 2, y: g.size.height / 2)
            .glow(color: Theme.pink.opacity(0.4), radius: 12)
        }
    }
}
