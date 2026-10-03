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
    }
}

struct RolePickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill").foregroundStyle(Theme.pink)
                Text("DroneBoyfriendTracker").font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.dreamy)
                Image(systemName: "sparkles").foregroundStyle(Theme.lilac)
            }
            Text("How is this iPhone being used?")
                .font(.system(size: 15, weight: .medium, design: .rounded))
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

    private func roleCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 38, weight: .bold)).foregroundStyle(Theme.pink)
                Text(title).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .frame(width: 220, height: 200)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Theme.dreamy, lineWidth: 2))
            )
            .shadow(color: Theme.pink.opacity(0.4), radius: 16)
        }
        .buttonStyle(.plain)
    }
}
