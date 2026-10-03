// Pink theme: soft rounded shapes, gradients and glow everywhere.

import SwiftUI

enum Theme {
    static let pink = Color(red: 1.0, green: 0.44, blue: 0.71)        // #FF6FB5
    static let softPink = Color(red: 1.0, green: 0.70, blue: 0.85)    // #FFB3D9
    static let lilac = Color(red: 0.79, green: 0.64, blue: 1.0)       // #C9A2FF
    static let peach = Color(red: 1.0, green: 0.80, blue: 0.70)
    static let plum = Color(red: 0.11, green: 0.06, blue: 0.10)       // #1D0F1A
    static let plumLight = Color(red: 0.24, green: 0.09, blue: 0.21)  // #3C1636
    static let panel = Color(red: 0.20, green: 0.10, blue: 0.18)
    static let text = Color(red: 1.0, green: 0.93, blue: 0.96)
    static let muted = Color(red: 0.79, green: 0.61, blue: 0.72)
    static let ok = Color(red: 0.49, green: 1.0, blue: 0.77)
    static let warn = Color(red: 1.0, green: 0.83, blue: 0.44)
    static let danger = Color(red: 1.0, green: 0.23, blue: 0.42)

    static let background = LinearGradient(colors: [plumLight, plum], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let candy = LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.78), Color(red: 0.89, green: 0.33, blue: 0.62)],
                                      startPoint: .top, endPoint: .bottom)
    static let dreamy = LinearGradient(colors: [softPink, lilac], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct PinkBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.pink.opacity(0.25), .clear], center: .topLeading, startRadius: 10, endRadius: 500)
            RadialGradient(colors: [Theme.lilac.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 450)
        }
        .ignoresSafeArea()
    }
}

/// Soft glossy capsule button.
struct CandyButtonStyle: ButtonStyle {
    var tint: LinearGradient = Theme.candy
    var glow: Color = Theme.pink
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.vertical, compact ? 7 : 11)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(tint)
                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                    .overlay(Capsule().fill(.white.opacity(0.18)).padding(.horizontal, 6).padding(.bottom, 14).blur(radius: 2).offset(y: -5))
            )
            .shadow(color: glow.opacity(configuration.isPressed ? 0.9 : 0.5), radius: configuration.isPressed ? 14 : 8)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension LinearGradient {
    static let secondaryCandy = LinearGradient(colors: [Color(red: 0.42, green: 0.20, blue: 0.38), Color(red: 0.30, green: 0.13, blue: 0.27)],
                                                startPoint: .top, endPoint: .bottom)
    static let lilacCandy = LinearGradient(colors: [Theme.lilac, Color(red: 0.62, green: 0.45, blue: 0.95)], startPoint: .top, endPoint: .bottom)
    static let mintCandy = LinearGradient(colors: [Color(red: 0.55, green: 1.0, blue: 0.82), Color(red: 0.30, green: 0.80, blue: 0.62)],
                                          startPoint: .top, endPoint: .bottom)
}

struct GlassCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.panel.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.pink.opacity(0.25), lineWidth: 1))
            )
            .shadow(color: Theme.pink.opacity(0.15), radius: 10)
    }
}
