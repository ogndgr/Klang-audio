public struct AggregateSpec: Equatable {
    public let name: String
    public let uid: String
    public let mainUID: String
    public let subDeviceUIDs: [String]
    public let tapUUIDs: [String]

    public static func make(outputUID: String, tapUUID: String) -> AggregateSpec {
        AggregateSpec(
            name: "Klang Aggregate",
            uid: "com.klang.aggregate",
            mainUID: outputUID,             // real hardware = clock
            subDeviceUIDs: [outputUID],
            tapUUIDs: [tapUUID])            // system audio, drift-corrected to the output
    }
}
