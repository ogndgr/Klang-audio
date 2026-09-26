public enum DeviceMatcher {
    /// Every physical output the user may target: real (non-virtual, non-aggregate)
    /// outputs, excluding BlackHole and Klang's own aggregate (which is virtual).
    public static func selectableOutputs(in devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        devices.filter {
            $0.isOutput && !$0.isVirtual
            && !($0.name.lowercased().contains("blackhole"))
        }
    }

    /// The user's chosen device when present; otherwise the system default output;
    /// otherwise (default is virtual or missing) the first physical output.
    public static func resolveTarget(chosenUID: String?, defaultUID: String?,
                                     in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        let outputs = selectableOutputs(in: devices)
        return outputs.first { $0.uid == chosenUID }
            ?? outputs.first { $0.uid == defaultUID }
            ?? outputs.first
    }

    /// After the system default output changed: the device to rebuild on, or nil to
    /// keep running as is. Only an automatic target follows, and only while the active
    /// device is still present (a vanished device deactivates instead).
    public static func followTarget(activeUID: String, chosenUID: String?, defaultUID: String?,
                                    in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        guard devices.contains(where: { $0.uid == activeUID }),
              let target = resolveTarget(chosenUID: chosenUID, defaultUID: defaultUID, in: devices),
              target.uid != activeUID,
              selectableOutputs(in: devices).contains(where: { $0.uid == defaultUID }) else { return nil }
        return target
    }
}
