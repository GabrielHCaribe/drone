import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            PinkBackground()
            switch model.role {
            case .remote: RemoteView(link: model.link)
            case .drone:
                if let follow = model.follow, let camera = model.camera {
                    DroneView(link: model.link, follow: follow, status: follow.status, camera: camera)
                }
            case nil: RolePickerView()
            }
        }
        .id(model.basicLook)  // the theme is static, so rebuild everything when the look changes
    }
}

struct RolePickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                if !Theme.basic { Image(systemName: "heart.fill").foregroundStyle(Theme.pink) }
                Text("DroneBoyfriendTracker")
                    .font(Theme.basic ? Font.system(size: 28, weight: .semibold) : Font.system(size: 34, weight: .heavy, design: Theme.fontDesign))
                    .foregroundStyle(Theme.dreamy)
                if !Theme.basic { Image(systemName: "sparkles").foregroundStyle(Theme.lilac) }
            }
            .onLongPressGesture(minimumDuration: 2) { model.toggleLook() }  // hidden look switch
            Text(Theme.basic ? "Select mode:" : "How is this iPhone being used?")
                .font(.system(size: 15, weight: .medium, design: Theme.fontDesign))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 20) {
                roleCard(icon: "gamecontroller.fill", title: "Remote", subtitle: "In your hands.\nSticks, manual flight,\ntuning, motor test.") {
                    model.activate(.remote)
                }
                roleCard(icon: "camera.aperture", title: "Drone", subtitle: "Mounted on the drone.\nCamera, vision,\nfollow mode.") {
                    model.activate(.drone)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func roleCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        if Theme.basic {
            Button(action: action) {
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 20, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.gray).multilineTextAlignment(.center)
                }
                .frame(width: 200, height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                VStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 38, weight: .bold)).foregroundStyle(Theme.pink)
                    Text(title).font(.system(size: 22, weight: .heavy, design: Theme.fontDesign)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 13, design: Theme.fontDesign)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
                .frame(width: 220, height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Theme.dreamy, lineWidth: 2))
                )
                .glow(color: Theme.pink.opacity(0.4), radius: 16)
            }
            .buttonStyle(.plain)
        }
    }
}
