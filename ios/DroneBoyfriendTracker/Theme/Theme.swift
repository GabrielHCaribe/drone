// Pink theme: soft rounded shapes, gradients and glow everywhere.
//
// Theme.basic swaps everything for a plain "first iteration" look (system
// colours, flat grey buttons, no glow or hearts). Toggled from "Switch look"
// in the … menu, or a 2 s long-press on the role picker title. Only the
// visuals change; behaviour is identical.

import SwiftUI

enum Theme {
    static var basic = UserDefaults.standard.bool(forKey: "basicLook")

    static var pink: Color { basic ? .blue : Color(red: 1.0, green: 0.44, blue: 0.71) }            // #FF6FB5
    static var softPink: Color { basic ? .white : Color(red: 1.0, green: 0.70, blue: 0.85) }       // #FFB3D9
    static var lilac: Color { basic ? .gray : Color(red: 0.79, green: 0.64, blue: 1.0) }           // #C9A2FF
    static var plum: Color { basic ? .black : Color(red: 0.11, green: 0.06, blue: 0.10) }          // #1D0F1A
    static var plumLight: Color { basic ? .black : Color(red: 0.24, green: 0.09, blue: 0.21) }     // #3C1636
    static var panel: Color { basic ? Color(white: 0.16) : Color(red: 0.20, green: 0.10, blue: 0.18) }
    static var text: Color { basic ? .white : Color(red: 1.0, green: 0.93, blue: 0.96) }
    static var muted: Color { basic ? .gray : Color(red: 0.79, green: 0.61, blue: 0.72) }
    static var ok: Color { basic ? .green : Color(red: 0.49, green: 1.0, blue: 0.77) }
    static var warn: Color { basic ? .yellow : Color(red: 1.0, green: 0.83, blue: 0.44) }
    static var danger: Color { basic ? .red : Color(red: 1.0, green: 0.23, blue: 0.42) }

    static var fontDesign: Font.Design { basic ? .default : .rounded }

    static var background: LinearGradient {
        basic ? .flat(.black) : LinearGradient(colors: [plumLight, plum], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var candy: LinearGradient {
        basic ? .flat(.blue)
              : LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.78), Color(red: 0.89, green: 0.33, blue: 0.62)],
                               startPoint: .top, endPoint: .bottom)
    }
    static var dreamy: LinearGradient {
        basic ? .flat(.white) : LinearGradient(colors: [softPink, lilac], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// Coloured glow in the pink theme; nothing in the basic look.
    func glow(color: Color, radius: CGFloat) -> some View {
        shadow(color: Theme.basic ? .clear : color, radius: Theme.basic ? 0 : radius)
    }
}

struct PinkBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            if !Theme.basic {
                RadialGradient(colors: [Theme.pink.opacity(0.25), .clear], center: .topLeading, startRadius: 10, endRadius: 500)
                RadialGradient(colors: [Theme.lilac.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 450)
            }
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
        if Theme.basic {
            configuration.label
                .font(.system(size: compact ? 13 : 15, weight: .regular))
                .foregroundStyle(.white)
                .padding(.vertical, compact ? 6 : 10)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(tint))
                .opacity(configuration.isPressed ? 0.6 : 1)
        } else {
            configuration.label
                .font(.system(size: compact ? 13 : 15, weight: .bold, design: Theme.fontDesign))
                .foregroundStyle(Theme.text)
                .padding(.vertical, compact ? 7 : 11)
                .padding(.horizontal, compact ? 12 : 16)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(tint)
                        .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                        .overlay(Capsule().fill(.white.opacity(0.18)).padding(.horizontal, 6).padding(.bottom, 14).blur(radius: 2).offset(y: -5))
                )
                .glow(color: glow.opacity(configuration.isPressed ? 0.9 : 0.5), radius: configuration.isPressed ? 14 : 8)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}

extension LinearGradient {
    static func flat(_ c: Color) -> LinearGradient { LinearGradient(colors: [c, c], startPoint: .top, endPoint: .bottom) }

    static var secondaryCandy: LinearGradient {
        Theme.basic ? .flat(Color(white: 0.28))
                    : LinearGradient(colors: [Color(red: 0.42, green: 0.20, blue: 0.38), Color(red: 0.30, green: 0.13, blue: 0.27)],
                                     startPoint: .top, endPoint: .bottom)
    }
    static var lilacCandy: LinearGradient {
        Theme.basic ? .flat(Color(white: 0.28))
                    : LinearGradient(colors: [Theme.lilac, Color(red: 0.62, green: 0.45, blue: 0.95)], startPoint: .top, endPoint: .bottom)
    }
    static var mintCandy: LinearGradient {
        Theme.basic ? .flat(Color(red: 0.1, green: 0.55, blue: 0.2))
                    : LinearGradient(colors: [Color(red: 0.55, green: 1.0, blue: 0.82), Color(red: 0.30, green: 0.80, blue: 0.62)],
                                     startPoint: .top, endPoint: .bottom)
    }
}

struct GlassCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        let r: CGFloat = Theme.basic ? 6 : 20
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(Theme.panel.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).stroke(Theme.pink.opacity(Theme.basic ? 0 : 0.25), lineWidth: 1))
            )
            .glow(color: Theme.pink.opacity(0.15), radius: 10)
    }
}
