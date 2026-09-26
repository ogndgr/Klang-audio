import CoreAudio
import AudioToolbox
import KlangCore

final class AggregateDevice {
    func create(_ spec: AggregateSpec) -> AudioDeviceID? {
        let sub: [[String: Any]] = spec.subDeviceUIDs.map { [kAudioSubDeviceUIDKey as String: $0] }
        let taps: [[String: Any]] = spec.tapUUIDs.map {
            [kAudioSubTapUIDKey as String: $0, kAudioSubTapDriftCompensationKey as String: 1]
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: spec.name,
            kAudioAggregateDeviceUIDKey as String: spec.uid,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceMainSubDeviceKey as String: spec.mainUID,
            kAudioAggregateDeviceSubDeviceListKey as String: sub,
            kAudioAggregateDeviceTapListKey as String: taps,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
        ]
        var id: AudioDeviceID = 0
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
        return st == noErr ? id : nil
    }

    func destroy(_ id: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
