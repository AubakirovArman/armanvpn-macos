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
                .fixedSize(horizontal: false, vertical: true)

            if cooling.selectedMode == .automatic {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Начало разгона"); Spacer(); Text("\(Int(cooling.startTemperature)) °C").monospacedDigit() }.font(.caption)
                    Slider(value: $cooling.startTemperature, in: 40...min(70, cooling.fullTemperature - 10), step: 1)
                    HStack { Text("Максимальные обороты"); Spacer(); Text("\(Int(cooling.fullTemperature)) °C").monospacedDigit() }.font(.caption)
                    Slider(value: $cooling.fullTemperature, in: max(75, cooling.startTemperature + 10)...85, step: 1)
                    Text("Начинаем с минимальных оборотов вентилятора. Короткие пики сглаживаются; разгон быстрее замедления. На верхнем пороге сразу включается максимум.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let status = cooling.status, status.controlling, status.policy.mode == .automatic {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 24) {
                        temperatureMetric("Самый горячий датчик", value: status.temperature)
                        temperatureMetric("После сглаживания", value: status.filteredTemperature)
                        temperatureMetric("Для расчёта оборотов", value: status.controlTemperature)
                    }
                    if let reason = status.automaticReason {
                        Label(reason, systemImage: "waveform.path").font(.caption).foregroundStyle(ArmanBrand.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(status.fans.sorted { $0.id < $1.id }.map { "Вентилятор \($0.id + 1): цель \(Int($0.target)) RPM" }.joined(separator: " · "))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text("В строке меню — средняя CPU/GPU. Здесь — максимум CPU/GPU и его сглаженное значение; разница до 1 °C удерживает обороты от мелких колебаний.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
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
            Text("Изменения применяются кнопкой. При 85 °C включается максимум. При сильном тепловом давлении macOS, сбое датчиков или потере связи на 15 секунд управление возвращается системе. Завершите TG Pro и другие программы управления вентиляторами перед включением нашего режима.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).background(ArmanBrand.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ArmanBrand.gold.opacity(0.15)))
    }

    private func temperatureMetric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f °C", $0) } ?? "—")
                .font(.callout.weight(.semibold)).monospacedDigit()
        }
    }
}
