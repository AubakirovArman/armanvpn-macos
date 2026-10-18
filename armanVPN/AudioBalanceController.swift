import Foundation
import Observation

@MainActor @Observable
final class AudioBalanceController {
    let lock: AudioBalanceLock
    private let persist: Bool
    var enabled: Bool {
        get { lock.enabled }
        set {
            lock.setEnabled(newValue)
            if persist { UserDefaults.standard.set(lock.enabled, forKey: "tools.audioBalanceLock") }
        }
    }

    init(startMonitoring: Bool = true) {
        persist = startMonitoring
        lock = AudioBalanceLock(hardware: CoreAudioBalanceHardware())
        if startMonitoring, UserDefaults.standard.bool(forKey: "tools.audioBalanceLock") {
            lock.setEnabled(true)
        }
    }

    var status: String {
        switch lock.state {
        case .off: "Баланс свободный"
        case .waiting: "Ждём устройство вывода"
        case .unsupported: "Баланс недоступен на этом выходе"
        case .centered: "Левый и правый каналы по центру"
        case .correcting: "Возвращаем баланс в центр"
        case .failed(let message): message
        }
    }
}
