import CoreAudio
import Foundation

/// A private, stereo, global Core Audio process tap of every process except Klang.
/// Tapped processes are muted on their direct path (`mutedWhenTapped`), so while the
/// tap is alive the listener hears only Klang's corrected output. Excluding Klang's
/// own process makes a feedback loop impossible. The tap dies with the process, so a
/// crash simply returns audio to normal (uncorrected) playback.
final class SystemAudioTap {
    let id: AudioObjectID
    let uuid: String

    init?() {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        desc.uuid = UUID()
        desc.name = "Klang System Audio"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return nil }
        id = tapID
        uuid = desc.uuid.uuidString
    }

    func destroy() {
        AudioHardwareDestroyProcessTap(id)
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }
}
