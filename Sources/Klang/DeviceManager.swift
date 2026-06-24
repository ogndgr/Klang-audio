import CoreAudio
import AudioToolbox
import KlangCore

final class DeviceManager {
    private let sys = AudioObjectID(kAudioObjectSystemObject)

    private func addr(_ sel: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func listDevices() -> [AudioDeviceInfo] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids)
        return ids.map { info(for: $0) }
    }

    private func info(for id: AudioDeviceID) -> AudioDeviceInfo {
        let inCh = channels(id, kAudioObjectPropertyScopeInput)
        let outCh = channels(id, kAudioObjectPropertyScopeOutput)
        return AudioDeviceInfo(
            id: id,
            uid: stringProp(id, kAudioDevicePropertyDeviceUID) ?? "",
            name: stringProp(id, kAudioObjectPropertyName) ?? "Unknown",
            isInput: inCh > 0, isOutput: outCh > 0,
            isVirtual: isVirtual(id),
            supportedRates: availableRates(id))
    }

    private func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                    alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func isVirtual(_ id: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        return t == kAudioDeviceTransportTypeVirtual || t == kAudioDeviceTransportTypeAggregate
    }

    private func availableRates(_ id: AudioDeviceID) -> [Double] {
        var a = addr(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                       count: Int(size) / MemoryLayout<AudioValueRange>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ranges)
        return ranges.map { $0.mMaximum }
    }

    private func stringProp(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf)
        return st == noErr ? (cf?.takeRetainedValue() as String?) : nil
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        listDevices().first { $0.uid == uid }?.id
    }

    func defaultOutputDeviceID() -> AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &id)
        return id
    }

    func setDefaultOutput(_ id: AudioDeviceID) {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var v = id
        AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
    }

    func setNominalSampleRate(_ rate: Double, deviceID: AudioDeviceID) {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var v = rate
        AudioObjectSetPropertyData(deviceID, &a, 0, nil, UInt32(MemoryLayout<Double>.size), &v)
    }

    func onDevicesChanged(_ handler: @escaping () -> Void) {
        var a = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(sys, &a, DispatchQueue.main) { _, _ in handler() }
    }

    func onDefaultOutputChanged(_ handler: @escaping () -> Void) {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(sys, &a, DispatchQueue.main) { _, _ in handler() }
    }
}
