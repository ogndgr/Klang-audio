import CoreAudio
import AudioToolbox
import KlangCore

final class AggregateDevice {
    func create(_ spec: AggregateSpec) -> AudioDeviceID? {
        let sub: [[String: Any]] = spec.subDeviceUIDs.map { uid in
            var d: [String: Any] = [kAudioSubDeviceUIDKey as String: uid]
            if spec.driftUIDs.contains(uid) {
                d[kAudioSubDeviceDriftCompensationKey as String] = 1
            }
            return d
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: spec.name,
            kAudioAggregateDeviceUIDKey as String: spec.uid,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceMasterSubDeviceKey as String: spec.masterUID,
            kAudioAggregateDeviceSubDeviceListKey as String: sub,
        ]
        var id: AudioDeviceID = 0
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
        return st == noErr ? id : nil
    }

    func destroy(_ id: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
