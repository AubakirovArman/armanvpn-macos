import AudioToolbox
import CoreAudio
import Foundation

/// Public HAL properties only. No audio capture, mixing, microphone permission or root helper.
@MainActor
final class CoreAudioBalanceHardware: AudioBalanceHardware {
    private struct Listener: Sendable {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    }
    private var listeners: [Listener] = []
    private var observedDevice: AudioObjectID?
    private var changed: (@MainActor () -> Void)?

    deinit {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
    }

    func output() throws -> AudioBalanceOutput? {
        let device = try defaultOutput()
        if changed != nil, observedDevice != device { observeDevice(device) }
        guard device != kAudioObjectUnknown else { return nil }
        let name = deviceName(device) ?? "Устройство вывода"
        guard let control = balanceControl(device) else {
            return .init(id: device, name: name, balance: nil, writable: false)
        }
        var property = address(control)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
        var writable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(device, &property, &writable))
        return .init(id: device, name: name, balance: Double(value), writable: writable.boolValue)
    }

    func center(_ output: AudioBalanceOutput) throws {
        // A route may change between reading its balance and applying the correction.
        guard try defaultOutput() == output.id, let control = balanceControl(output.id) else {
            throw AudioBalanceError(message: "Аудиовыход изменился. Проверяем новое устройство.")
        }
        var property = address(control)
        var value: Float32 = 0.5
        try check(AudioObjectSetPropertyData(output.id, &property, 0, nil,
                                            UInt32(MemoryLayout<Float32>.size), &value))
    }

    func startObserving(_ changed: @escaping @MainActor () -> Void) throws {
        stopObserving()
        self.changed = changed
        do {
            try listen(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal))
            try listen(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal))
        } catch { stopObserving(); throw error }
    }

    func stopObserving() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        listeners.removeAll()
        observedDevice = nil
        changed = nil
    }

    private func observeDevice(_ device: AudioObjectID) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for var listener in listeners where listener.object != system {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        listeners.removeAll { $0.object != system }
        observedDevice = device
        guard device != kAudioObjectUnknown else { return }
        // Drivers differ in whether they notify pan, virtual balance or channel volume.
        // The low-frequency watchdog also covers drivers without notifications.
        try? listen(device, .init(mSelector: kAudioObjectPropertySelectorWildcard,
                                 mScope: kAudioObjectPropertyScopeWildcard,
                                 mElement: kAudioObjectPropertyElementWildcard))
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
        var property = address
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { [weak self] count, addresses in
            let relevant: Set<AudioObjectPropertySelector> = [
                kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
                kAudioDevicePropertyStereoPan, kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
                kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyVolumeDecibels,
                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyDeviceIsAlive,
                kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyDataSource
            ]
            guard (0..<Int(count)).contains(where: { relevant.contains(addresses[$0].mSelector) }) else { return }
            Task { @MainActor [weak self] in self?.changed?() }
        }
        try check(AudioObjectAddPropertyListenerBlock(object, &property, .main, block))
        listeners.append(.init(object: object, address: property, block: block))
    }

    private func defaultOutput() throws -> AudioObjectID {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device))
        return device
    }

    private func balanceControl(_ device: AudioObjectID) -> AudioObjectPropertySelector? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioDevicePropertyStereoPan] {
            var property = address(selector)
            if AudioObjectHasProperty(device, &property) { return selector }
        }
        return nil
    }

    private func deviceName(_ device: AudioObjectID) -> String? {
        var property = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw AudioBalanceError(message: "Не удалось настроить баланс звука (Core Audio: \(status)). Проверим устройство снова.")
        }
    }
}

struct AudioBalanceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
