import SwiftUI

struct MenuBarPanel: View {
    @Bindable var vpn: VPNController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Image("ArmanPoster").resizable().scaledToFill()
                    .frame(width: 360, height: 210, alignment: .top).clipped()
                LinearGradient(colors: [.clear, ArmanBrand.night.opacity(0.5), ArmanBrand.night], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 7) {
                    Text("ARMAN NETWORK").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(3).foregroundStyle(ArmanBrand.gold)
                    Text(vpn.connected ? "Добро пожаловать\nв мощную сеть." : "Свои люди.\nСвоя сеть.")
                        .font(.system(size: 25, weight: .semibold)).lineSpacing(1)
                }.padding(20)
            }.frame(height: 210)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Circle().fill(vpn.connected ? ArmanBrand.cyan : ArmanBrand.gold).frame(width: 6, height: 6)
                    Text(vpn.phase).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if vpn.busy { ProgressView().controlSize(.mini) }
                    if let since = vpn.details?.since {
                        Text(since, style: .timer).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                ArmanMemoryCard(compact: true)
                if let error = vpn.error {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
                Button {
                    if vpn.connected || vpn.busy { vpn.disconnect() }
                    else if vpn.profile.host.isEmpty || vpn.profile.username.isEmpty { showMainWindow() }
                    else { vpn.connect() }
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text(vpn.connected || vpn.busy ? "Отключиться" : "Войти в сеть Армана")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.font(.system(size: 13, weight: .semibold)).padding(.vertical, 9).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain).foregroundStyle(ArmanBrand.night)
                .background(ArmanBrand.gold, in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button("Открыть VPN", systemImage: "arrow.up.right.square") { showMainWindow() }
                    Spacer()
                    Button("Выход") { NSApp.terminate(nil) }
                        .help("Закрыть приложение. Активный туннель продолжит работать.")
                }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.58))
            }.padding(18)
        }
        .frame(width: 360).background(ArmanBrand.night).preferredColorScheme(.dark)
        .onChange(of: vpn.certificate?.id) { _, certificate in if certificate != nil { showMainWindow() } }
        .onChange(of: vpn.challenge) { _, challenge in if challenge != nil { showMainWindow() } }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
