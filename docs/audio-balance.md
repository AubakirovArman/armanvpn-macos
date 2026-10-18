# Stereo balance lock

Version 1.9 adds a remembered, opt-in checkbox in **Мой Mac → Держать баланс по центру**.
It operates independently of the VPN and temperature monitoring. The process must remain
running; closing its window is fine. It does not install an audio driver or use the microphone.

## System integration

`CoreAudioBalanceHardware` uses public HAL properties on the current default output:

1. `kAudioHardwareServiceDeviceProperty_VirtualMainBalance` when available. Core Audio
   adjusts the relative volume of the device's preferred stereo pair.
2. Otherwise, `kAudioDevicePropertyStereoPan`.

Both use 0.0 for left, 1.0 for right, and 0.5 for center. The adapter checks readability
and writability and writes only the balance property. It never sets master volume or mute,
never changes the default output, and never downmixes audio. Unsupported/read-only devices
are reported explicitly. An enabled lock waits for a compatible output rather than claiming
that an unsupported device is protected.

Official API references:
- [Virtual main balance](https://developer.apple.com/documentation/audiotoolbox/kaudiohardwareservicedeviceproperty_virtualmainbalance)
- [Stereo pan](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertystereopan)
- [Property listeners](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:))

The declarations and behavior were also checked in the installed Xcode SDK headers
`AudioHardwareService.h` and `AudioHardware.h`.

## Lifecycle and correctness

- Default-output/device notifications rebind the listener to the active device.
- Balance, volume and route notifications are coalesced over 120 ms.
- A three-second watchdog covers missed driver notifications, wake and temporary Core Audio
  failures. This is a property check, not audio capture or processing.
- One main actor serializes enable/disable, callbacks and corrections. Queued callbacks
  recheck the enabled flag. Disabling cancels pending work, removes listeners and stops
  the watchdog immediately; it leaves the current balance in place.
- The adapter rechecks the default output immediately before a write. After writing,
  the lock reads back the device and balance before displaying success.
- A tolerance of 0.005 accommodates quantized device controls. Correction attempts on
  the same device are limited to at most one per second; self-generated events do not
  cause redundant writes. Persistent errors remain visible and are retried.
- Listener blocks capture weak references and are removed on stop/deinitialization.
- Only the enabled preference is saved in UserDefaults (`tools.audioBalanceLock`).
  New installations default to off. No audio content or device identifiers are persisted.

## Validation on 2026-10-18

Ten deterministic tests cover off/on behavior, midpoint quantization, unsupported/read-only
and malformed values, disconnect/reconnect, switching during a write, read/write failures,
readback verification, bounded retries, notification bursts, observation failure and
cancellation of queued events on disable. All 52 package tests pass.

The production Core Audio adapter and lock were additionally exercised on an M1 Max MacBook:

- Built-in speakers: enabling centered an off-center balance; subsequent external drift
  was corrected through a property listener.
- Master volume and mute remained unchanged during correction.
- Switching to Elgato Wave:3 correctly showed unsupported balance control, and returning
  to built-in speakers resumed correction.
- After disable, a manually selected balance of 0.75 survived beyond the watchdog interval.
- The original output device and original speaker balance were restored after the test.

No sound was played by the test. Bluetooth reconnect and actual sleep/wake were not physically
exercised in this run. Driver-specific behavior still needs testing with those devices.
