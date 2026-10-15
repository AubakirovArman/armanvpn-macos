import ServiceManagement
import SwiftUI

struct ContentView: View {
    @Bindable var vpn: VPNController
    var personality = ArmanPersonality.current
    @State private var showingLog = false
    private let accent = ArmanBrand.gold

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("armanVPN").font(.system(size: 27, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: "sparkles").foregroundStyle(accent)
                }
                Text("СВЯЗЬ РЕШАЕТ. АРМАН ПОДКЛЮЧАЕТ.")
                    .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1.4)
                    .foregroundStyle(accent)
                Image("ArmanPoster").resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.25)))
                    .accessibilityLabel("Постер Армана с орлом, логотипами Самрук-Казына и Казахтелеком")
                VStack(alignment: .leading, spacing: 6) {
                    sidebarButton("Подключение", symbol: "network", selected: !showingLog) { showingLog = false }
                    sidebarButton("Журнал", symbol: "list.bullet.rectangle", selected: showingLog) { showingLog = true }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Text("GOOD CONNECTIONS.\nBETTER PEOPLE.")
                        .font(.system(size: 18, weight: .semibold)).tracking(0.4).foregroundStyle(accent)
                    Text("ДЛЯ СВОИХ · INTERNAL EDITION")
                        .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.38))
                }
                Divider()
                Label(vpn.connected ? "Туннель активен" : "Туннель отключён", systemImage: vpn.connected ? "circle.fill" : "circle")
                    .font(.caption).foregroundStyle(vpn.connected ? accent : .secondary)
            }
            .padding(24).frame(width: 290).frame(maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.08), ArmanBrand.night], startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle().fill(accent.opacity(0.12)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(showingLog ? "ЗАКУЛИСЬЕ СОЕДИНЕНИЯ" : "ARMAN NETWORK / FRIENDS EDITION")
                                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(accent)
                            Text(showingLog ? "Всё под контролем." : "Мощная сеть.\nЛичный подход.")
                                .font(.system(size: 32, weight: .semibold)).lineSpacing(1)
                        }
                        Spacer()
                        if vpn.busy { ProgressView().controlSize(.small) }
                    }
                    if showingLog { logView } else { connectionView }
                }.padding(30).frame(maxWidth: 710).frame(maxWidth: .infinity)
            }
            .background(ArmanBrand.night)
        }
        .frame(minWidth: 960, minHeight: 700).tint(accent).preferredColorScheme(.dark)
        .sheet(item: $vpn.certificate) { certificate in
            CertificateView(certificate: certificate, accept: vpn.acceptCertificate, reject: vpn.rejectCertificate)
        }
        .sheet(isPresented: Binding(get: { vpn.challenge != nil }, set: { if !$0 { vpn.cancelChallenge() } })) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Подтверждение входа").font(.title2.bold())
                Text(vpn.challenge ?? "")
                SecureField("Код подтверждения", text: $vpn.challengeAnswer)
                    .textFieldStyle(.roundedBorder).onSubmit { vpn.sendChallenge() }
                HStack {
                    Button("Отмена", role: .cancel) { vpn.cancelChallenge() }
                    Spacer()
                    Button("Продолжить") { vpn.sendChallenge() }.buttonStyle(.borderedProminent)
                        .disabled(vpn.challengeAnswer.isEmpty)
                }
            }.padding(28).frame(width: 420)
        }
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Image(systemName: vpn.connected ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(vpn.connected ? ArmanBrand.cyan : accent)
                    .frame(width: 76, height: 88)
                    .background(accent.opacity(vpn.connected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 6) {
                    Text(vpn.phase.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.5).foregroundStyle(vpn.connected ? ArmanBrand.cyan : accent)
                    Text(vpn.connected ? ArmanPersonality.connectedMessage : ArmanPersonality.idleMessage)
                        .font(.system(size: 21, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let info = vpn.details {
                        Text("\(info.address) · \(info.interface)").font(.callout.monospaced()).foregroundStyle(.secondary)
                        if let since = info.since {
                            Text("Подключено с \(since.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Орёл готов. Осталось нажать кнопку.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button { vpn.connected || vpn.busy ? vpn.disconnect() : vpn.connect() } label: {
                    Image(systemName: "power").font(.system(size: 23, weight: .medium)).frame(width: 54, height: 54)
                }
                .buttonStyle(.plain).background(accent, in: Circle())
                .foregroundStyle(ArmanBrand.night)
                .help(vpn.connected || vpn.busy ? "Отключить" : "Подключить")
                .accessibilityLabel(vpn.connected || vpn.busy ? "Отключить VPN" : "Подключить VPN")
            }
            .padding(18).background(ArmanBrand.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.18)))

            ArmanMemoryCard(personality: personality)

            if let error = vpn.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            GroupBox {
                Form {
                    LabeledContent("Сервер") {
                        HStack {
                            TextField("Сервер", text: $vpn.profile.host, prompt: Text("vpn.company.kz")).labelsHidden()
                            Text("Порт").foregroundStyle(.secondary)
                            TextField("Порт", text: $vpn.profile.port).labelsHidden().frame(width: 65)
                        }
                    }
                    TextField("Логин", text: $vpn.profile.username)
                    SecureField("Пароль", text: $vpn.password, prompt: Text(vpn.profile.rememberPassword ? "Сохранён в Связке ключей" : "Пароль VPN"))
                    Toggle("Сохранить пароль в Связке ключей", isOn: Binding(
                        get: { vpn.profile.rememberPassword }, set: vpn.setRememberPassword))
                    if !vpn.options.isEmpty {
                        Picker("Способ входа", selection: $vpn.profile.loginType) {
                            ForEach(vpn.options) { Text($0.title).tag($0.id) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Проверить сервер и сертификат", systemImage: "checkmark.shield") { vpn.inspectServer() }
                    }
                }.formStyle(.columns).textFieldStyle(.roundedBorder).padding(12)
            } label: { Text("Параметры подключения").font(.headline) }
            .disabled(vpn.busy || vpn.connected)

            DisclosureGroup("Дополнительные параметры") {
                Form {
                    Picker("Туннель", selection: $vpn.profile.tunnel) {
                        Text("IPsec").tag("IPsec")
                        Text("SSL (по умолчанию)").tag("SSL")
                    }
                    Picker("Транспорт IPsec", selection: $vpn.profile.transport) {
                        Text("Автоматически").tag("AutoDetect")
                        Text("UDP").tag("Udp")
                        Text("TCP 443").tag("Tcpt")
                    }.disabled(vpn.profile.tunnel != "IPsec")
                    Toggle("Восстанавливать после разрыва", isOn: $vpn.profile.reconnect)
                    Text("Через VPN направляются маршруты, полученные от шлюза.").font(.caption).foregroundStyle(.secondary)
                }.formStyle(.columns).padding(.top, 12)
            }.disabled(vpn.busy || vpn.connected)

            HStack(spacing: 14) {
                Image(systemName: "gearshape.2").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Системная служба").font(.callout.weight(.medium))
                    Text(vpn.serviceLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Управление") {
                    Button("Разрешить службу…") { vpn.enableService() }
                    Button("Скопировать данные для отзыва") { vpn.copyFeedbackDetails() }
                    Button("Удалить системную службу", role: .destructive) { vpn.disableService() }
                        .disabled(vpn.connected || vpn.busy)
                }.fixedSize()
            }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Проверка стабильности").font(.callout.weight(.medium))
                    Text("Наблюдение за текущей сессией; кнопка запускает таймер проверки.").font(.caption).foregroundStyle(.secondary)
                    if let started = vpn.testStarted {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            let elapsed = min(600, Int(context.date.timeIntervalSince(started)))
                            Text("\(elapsed / 60):\(String(format: "%02d", elapsed % 60)) / 10:00 · разрывов: \(vpn.testDrops)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(vpn.testResult ?? "10 минут непрерывного соединения").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Начать тест") { vpn.startTest() }.disabled(!vpn.connected || vpn.testStarted != nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(vpn.networkLabel, systemImage: "network")
                if let reason = vpn.lastDisconnectReason { Text("Последний разрыв: \(reason)") }
                if !vpn.diagnosticsAvailable { Text("Причины разрывов недоступны: проверьте версию системной службы.") }
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let details = vpn.details {
                HStack(spacing: 20) {
                    Label(ByteCountFormatter.string(fromByteCount: details.received, countStyle: .binary), systemImage: "arrow.down")
                    Label(ByteCountFormatter.string(fromByteCount: details.sent, countStyle: .binary), systemImage: "arrow.up")
                    Spacer()
                    Text("\(details.tunnelType) / \(details.transport)")
                }.font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Локальные события подключения. Пароли и ответы MFA сюда не записываются.").font(.callout).foregroundStyle(.secondary)
            if vpn.events.isEmpty { ContentUnavailableView("Событий пока нет", systemImage: "list.bullet.rectangle") }
            ForEach(Array(vpn.events.enumerated()), id: \.offset) { _, event in
                Text(event).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Divider()
            }
        }
    }

    private func sidebarButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(11)
                .background(selected ? accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? accent : .primary)
        }.buttonStyle(.plain)
    }
}

private struct CertificateView: View {
    let certificate: PeerCertificate
    let accept: (Bool) -> Void
    let reject: () -> Void
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Доверять сертификату?", systemImage: "checkmark.shield").font(.title2.weight(.semibold))
            Text("При первом подключении подтвердите подлинность сервера. Сверьте отпечаток с администратором вашей сети.").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow { Text("Шлюз").foregroundStyle(.secondary); Text(certificate.endpoint) }
                GridRow { Text("Имя").foregroundStyle(.secondary); Text(certificate.subject) }
                GridRow { Text("Издатель").foregroundStyle(.secondary); Text(certificate.issuer) }
                GridRow { Text("Действует до").foregroundStyle(.secondary); Text(certificate.expires?.formatted(date: .numeric, time: .omitted) ?? "Неизвестно") }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ОТПЕЧАТОК SHA-256").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(certificate.fingerprint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            if !certificate.systemTrusted {
                Label("macOS не смогла подтвердить сертификат автоматически. Доверие будет действовать только в armanVPN для этого шлюза.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("При замене сертификата приложение снова запросит ваше решение.").font(.caption).foregroundStyle(.secondary)
            Toggle("Запомнить доверие к этому сертификату", isOn: $remember)
            Text(remember ? "Доверие сохранится для этого шлюза." : "Доверие действует только в текущем сеансе приложения.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Не доверять", role: .cancel, action: reject)
                Spacer()
                Button("Доверять и продолжить") { accept(remember) }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 550).interactiveDismissDisabled()
    }
}
