import Charts
import SwiftUI

struct HubOverview: View {
    @Bindable var vpn: VPNController
    @Bindable var tools: DesktopTools

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                Image(systemName: vpn.connected ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 32)).foregroundStyle(vpn.connected ? ArmanBrand.cyan : ArmanBrand.gold)
                VStack(alignment: .leading, spacing: 5) {
                    Text("СЕТЬ АРМАНА").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(ArmanBrand.gold)
                    Text(vpn.phase).font(.title3.weight(.semibold))
                    Text(vpn.connected ? "Рабочие ресурсы — на расстоянии клика." : "Подключение к твоей рабочей сети.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Открыть", systemImage: "arrow.up.right") { tools.section = .vpn }.buttonStyle(.bordered)
            }.padding(20).hubCard()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HubEyebrow(title: "CODEX", symbol: "sparkles", color: ArmanBrand.cyan)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(tools.menuQuota).font(.system(size: 45, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("осталось").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(tools.codex?.menuWindow?.title ?? "Лимиты аккаунта").font(.callout)
                    Text(tools.codexError != nil ? "Нужно обновить данные" : "Запас для твоей следующей большой идеи.")
                        .font(.caption).foregroundStyle(.secondary).frame(height: 32, alignment: .top)
                    Button("Лимиты и обновление", systemImage: "arrow.up.right") { tools.section = .codex }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(ArmanBrand.cyan)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).hubCard(tint: ArmanBrand.cyan)

                VStack(alignment: .leading, spacing: 14) {
                    HubEyebrow(title: "МОЙ MAC", symbol: "thermometer.medium", color: ArmanBrand.gold)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(tools.menuTemperature).font(.system(size: 45, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("CPU/GPU · средняя").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(fanSummary).font(.callout)
                    Text("Температуры и вентиляторы — прямо здесь.")
                        .font(.caption).foregroundStyle(.secondary).frame(height: 32, alignment: .top)
                    Button("Посмотреть датчики", systemImage: "arrow.up.right") { tools.section = .mac }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(ArmanBrand.gold)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).hubCard(tint: ArmanBrand.gold)
            }
            TemperatureHistoryView(points: tools.temperatureHistory, title: tools.temperatureLabel)
            ArmanMemoryCard()
            Label("Инструменты работают и при отключённом VPN", systemImage: "square.stack.3d.up")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fanSummary: String {
        guard tools.healthEnabled else { return "Мониторинг выключен" }
        guard let health = tools.health else { return "Считываем датчики…" }
        if health.fanCount == 0 { return "Безвентиляторный Mac" }
        return "Вентиляторов: \(health.fans.count)"
    }
}

struct CodexUsageView: View {
    @Bindable var tools: DesktopTools

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Твой аккаунт Codex", systemImage: "sparkles").font(.headline)
                Spacer()
                if tools.codexLoading { ProgressView().controlSize(.small) }
                Button("Обновить", systemImage: "arrow.clockwise") { Task { await tools.refreshCodex() } }
                    .disabled(tools.codexLoading || !tools.codexEnabled)
            }
            if let error = tools.codexError {
                Label(error, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).hubCard()
            }
            if let snapshot = tools.codex, !snapshot.windows.isEmpty {
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(window.bucket == "codex" ? "CODEX" : window.bucket.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(ArmanBrand.cyan)
                                Text(window.title).font(.title3.weight(.semibold))
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(window.percentage).font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text("осталось").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: window.remaining, total: 100).tint(window.remaining <= 10 ? .orange : ArmanBrand.cyan)
                        if let reset = window.resetsAt {
                            HStack {
                                Label("Обновление лимита", systemImage: "clock")
                                Spacer()
                                Text(reset.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(22).hubCard(tint: ArmanBrand.cyan)
                }
            } else if !tools.codexEnabled {
                Label("Проверка лимитов выключена. Её можно включить ниже.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading).hubCard()
            } else if tools.codexLoading {
                VStack(spacing: 14) { ProgressView(); Text("Получаем лимиты из Codex…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).padding(36).hubCard()
            } else {
                ContentUnavailableView("Подключи свой Codex", systemImage: "sparkles",
                                       description: Text("Лимиты появятся после установки Codex и входа в аккаунт ChatGPT на этом Mac."))
                Button("Открыть Codex", systemImage: "arrow.up.right.square") { tools.openCodex() }
            }
            if let updated = tools.codexUpdatedAt {
                Text("Последние полученные данные: \(updated.formatted(date: .omitted, time: .standard)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Проверять лимиты Codex", isOn: $tools.codexEnabled)
                    .onChange(of: tools.codexEnabled) { _, enabled in if enabled { Task { await tools.refreshCodex() } } }
                Toggle("Показывать остаток в строке меню", isOn: $tools.showCodexInMenu)
                Divider()
                Text("Проверка каждые 2 минуты. В строке меню показывается недельный остаток; если недельного окна нет — первое доступное. Данные относятся ко всему аккаунту.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Отображаем только окна, которые передал Codex. Отсутствующее окно не означает, что лимит исчерпан.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Открыть Codex", systemImage: "arrow.up.right.square") { tools.openCodex() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(ArmanBrand.cyan)
            }.padding(20).hubCard()
        }
    }
}

struct AudioBalanceCard: View {
    @Bindable var audio: AudioBalanceController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HubEyebrow(title: "ЗВУК · СТЕРЕОБАЛАНС", symbol: "headphones", color: ArmanBrand.cyan)
                Spacer()
                Image(systemName: audio.lock.state == .centered ? "lock.fill" : "lock.open")
                    .foregroundStyle(audio.lock.state == .centered ? ArmanBrand.cyan : .secondary)
            }
            Toggle("Держать баланс по центру", isOn: $audio.enabled)
                .toggleStyle(.checkbox).font(.callout.weight(.medium))
            HStack(alignment: .top, spacing: 10) {
                Text("L = R").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(8).background(ArmanBrand.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(audio.status).font(.callout)
                    if audio.enabled, let device = audio.lock.output {
                        Text(device.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(audio.lock.state == .unsupported
                 ? "Устройство не предоставляет macOS регулятор баланса. При переключении на совместимые наушники или динамики фиксация заработает автоматически."
                 : "Стерео остаётся стерео. При смене наушников баланс выровняется автоматически. Снимите галочку, чтобы настраивать его свободно.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Работает, пока armanVPN запущен, в том числе со скрытым окном.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).hubCard(tint: ArmanBrand.cyan)
    }
}

struct MacHealthView: View {
    @Bindable var tools: DesktopTools

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AudioBalanceCard(audio: tools.audioBalance)
            HStack(spacing: 16) {
                temperatureTile("CPU · максимум", value: tools.health?.cpuTemperature, symbol: "cpu")
                temperatureTile("GPU · максимум", value: tools.health?.gpuTemperature, symbol: "square.3.layers.3d")
            }
            TemperatureHistoryView(points: tools.temperatureHistory, title: tools.temperatureLabel)
            if let error = tools.healthError {
                Label(error, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            CoolingControlsView(cooling: tools.cooling, fans: tools.health?.fans ?? [])
            VStack(alignment: .leading, spacing: 18) {
                HubEyebrow(title: "ВЕНТИЛЯТОРЫ", symbol: "fan", color: ArmanBrand.gold)
                if tools.health?.fanCount == 0 {
                    Text("У этого Mac нет вентиляторов.").foregroundStyle(.secondary)
                } else if let health = tools.health, !health.fans.isEmpty {
                    ForEach(health.fans) { fan in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Вентилятор \(fan.id + 1)", systemImage: "fanblades")
                                Spacer()
                                Text(fan.rpm.map { "\(Int($0.rounded())) RPM" } ?? "Нет данных").monospacedDigit().fontWeight(.semibold)
                            }
                            if let rpm = fan.rpm, let maximum = fan.maximum, maximum > 0 {
                                ProgressView(value: min(maximum, max(0, rpm)), total: maximum).tint(ArmanBrand.gold)
                            }
                            HStack {
                                Text(fan.modeLabel)
                                Spacer()
                                if let maximum = fan.maximum { Text("до \(Int(maximum)) RPM") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        if fan.id != health.fans.last?.id { Divider() }
                    }
                } else {
                    Text(tools.healthEnabled ? "Данные о вентиляторах пока недоступны." : "Мониторинг выключен.").foregroundStyle(.secondary)
                }
            }.padding(20).hubCard()

            VStack(alignment: .leading, spacing: 16) {
                Toggle("Читать датчики Mac", isOn: $tools.healthEnabled)
                    .onChange(of: tools.healthEnabled) { _, enabled in if enabled { Task { await tools.refreshHealth() } } }
                Toggle("Показывать температуру в строке меню", isOn: $tools.showTemperatureInMenu)
                Toggle("Показывать обороты в строке меню", isOn: $tools.showFansInMenu)
                Text("Обновление каждые 3 секунды. CPU и GPU — максимальные значения доступных датчиков соответствующей группы.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("В строке меню — средняя температура по датчикам CPU/GPU и фактические RPM вентиляторов. Два значения RPM идут по порядку: вентилятор 1 / 2.")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = tools.health?.sampledAt {
                    Text("Последнее измерение: \(date.formatted(date: .omitted, time: .standard))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }.padding(20).hubCard()

            DisclosureGroup("Все доступные датчики · \(tools.health?.temperatures.count ?? 0)") {
                LazyVStack(spacing: 0) {
                    ForEach(tools.health?.temperatures ?? []) { sensor in
                        HStack {
                            Text("\(sensor.group) · \(sensor.id)")
                            Spacer()
                            Text("\(sensor.celsius, specifier: "%.1f") °C").monospacedDigit()
                        }.font(.caption).padding(.vertical, 7)
                    }
                }
            }.disclosureGroupStyle(FullWidthDisclosureStyle()).hubCard()
        }
    }

    private func temperatureTile(_ title: String, value: Double?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HubEyebrow(title: title.uppercased(), symbol: symbol, color: ArmanBrand.gold)
            Text(tools.temperatureIsFresh ? value.map { "\(Int($0.rounded()))°" } ?? "—" : "—")
                .font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).hubCard()
    }
}

struct TemperatureHistoryView: View {
    let points: [TemperaturePoint]
    var title = "CPU"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Температура · \(title)").font(.callout.weight(.medium))
                Spacer()
                Text("ПОСЛЕДНИЕ 3 МИН · °C").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            }
            if points.count > 1 {
                Chart(points) { point in
                    AreaMark(x: .value("Время", point.date), yStart: .value("Ноль", 0), yEnd: .value("°C", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [ArmanBrand.gold.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Время", point.date), y: .value("°C", point.value))
                        .interpolationMethod(.monotone).foregroundStyle(ArmanBrand.gold).lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...max(100, (points.map(\.value).max() ?? 90) + 5))
                .chartXAxis(.hidden).chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 105)
            } else {
                HStack { Spacer(); Text("История появится после нескольких измерений.").font(.caption).foregroundStyle(.secondary); Spacer() }.frame(height: 105)
            }
        }.padding(20).hubCard()
    }
}

struct HubEyebrow: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4).foregroundStyle(color)
    }
}

struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Развёрнуто" : "Свёрнуто")
            if configuration.isExpanded {
                configuration.content.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }
}

private extension View {
    func hubCard(tint: Color = ArmanBrand.gold) -> some View {
        background(ArmanBrand.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.15)))
    }
}

struct SuperAppMenuLabel: View {
    let connected: Bool
    @Bindable var tools: DesktopTools
    var body: some View {
        Image(nsImage: MenuBarStatusImage.make(connected: connected,
              quota: tools.showCodexInMenu ? tools.menuQuota : nil,
              temperature: tools.showTemperatureInMenu ? tools.menuTemperature : nil,
              fans: tools.showFansInMenu ? tools.menuFans : nil))
            .accessibilityLabel(tools.menuDescription)
            .help(tools.menuDescription)
    }
}
