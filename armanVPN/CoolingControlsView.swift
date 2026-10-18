import SwiftUI

struct CoolingControlsView: View {
    @Bindable var cooling: CoolingController
    let fans: [FanReading]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Управление охлаждением", systemImage: "fanblades").font(.headline)
                Spacer()
                if cooling.busy { ProgressView().controlSize(.small) }
            }
            Picker("Режим охлаждения", selection: $cooling.selectedMode) {
                ForEach(CoolingMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(cooling.selectedMode.explanation).font(.callout).foregroundStyle(.secondary)

            if cooling.selectedMode == .automatic {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Начало разгона"); Spacer(); Text("\(Int(cooling.startTemperature)) °C").monospacedDigit() }.font(.caption)
                    Slider(value: $cooling.startTemperature, in: 40...min(70, cooling.fullTemperature - 10), step: 1)
                    HStack { Text("Максимальные обороты"); Spacer(); Text("\(Int(cooling.fullTemperature)) °C").monospacedDigit() }.font(.caption)
                    Slider(value: $cooling.fullTemperature, in: max(75, cooling.startTemperature + 10)...85, step: 1)
                    Text("Плавная кривая от 30% до 100%. При остывании обороты снижаются постепенно.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if cooling.selectedMode == .manual {
                ForEach(fans) { fan in
                    if let maximum = fan.maximum, maximum.isFinite, maximum > 0 {
                        let minimum = max(fan.minimum ?? 0, min(1200, maximum))
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Вентилятор \(fan.id + 1)")
                                Spacer()
                                Text("\(Int(cooling.target(for: fan))) RPM").monospacedDigit().fontWeight(.semibold)
                            }.font(.callout)
                            Slider(value: Binding(get: { cooling.target(for: fan) }, set: { cooling.manualTargets[fan.id] = $0 }), in: minimum...maximum, step: 1)
                                .accessibilityLabel("Обороты вентилятора \(fan.id + 1)")
                            HStack { Text("\(Int(minimum)) RPM"); Spacer(); Text("\(Int(maximum)) RPM") }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error = cooling.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let message = cooling.status?.message {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if cooling.status?.thermalOverride == true {
                Label("Температурная защита: максимальные обороты до охлаждения ниже 80 °C.", systemImage: "thermometer.sun.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Активно: \(cooling.status?.policy.mode.title ?? "управление armanVPN не включено")").font(.caption.weight(.medium))
                    Text("Служба охлаждения: \(cooling.serviceLabel)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Служба") {
                    Button("Разрешить службу…") { cooling.registerService() }
                    Button("Удалить службу охлаждения", role: .destructive) { Task { await cooling.unregisterService() } }
                        .disabled(cooling.ownsSession)
                }.fixedSize().disabled(cooling.busy)
                Button("Применить", systemImage: "checkmark") { Task { await cooling.apply(fans: fans) } }
                    .buttonStyle(.borderedProminent).disabled(cooling.busy || (fans.isEmpty && cooling.selectedMode != .system))
            }
            if cooling.ownsSession {
                Button("Вернуть управление macOS", systemImage: "arrow.uturn.backward") { Task { await cooling.returnToSystem() } }
            } else if cooling.serviceLabel != "Разрешена" {
                Button("Разрешить службу охлаждения…", systemImage: "lock.open") { cooling.registerService() }
            }
            Divider()
            Text("Изменения применяются кнопкой. При 85 °C включается максимум; при потере связи на 15 секунд управление возвращается macOS. Завершите TG Pro и другие программы управления вентиляторами перед включением нашего режима.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(ArmanBrand.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ArmanBrand.gold.opacity(0.15)))
    }
}
