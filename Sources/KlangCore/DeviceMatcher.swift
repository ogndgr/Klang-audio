public enum DeviceMatcher {
    public static func blackHole(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        devices.first { $0.isInput && ($0.name.lowercased().contains("blackhole")
            || $0.uid.lowercased().contains("blackhole")) }
    }

    public static func physicalOutput(in devices: [AudioDeviceInfo],
                                      excludingUID: String?) -> AudioDeviceInfo? {
        devices.first {
            $0.isOutput && !$0.isVirtual
            && !($0.name.lowercased().contains("blackhole"))
            && $0.uid != excludingUID
        }
    }
}
