public struct AggregateSpec: Equatable {
    public let name: String
    public let uid: String
    public let masterUID: String
    public let subDeviceUIDs: [String]
    public let driftUIDs: [String]

    public static func make(outputUID: String, inputUID: String) -> AggregateSpec {
        AggregateSpec(
            name: "Klang Aggregate",
            uid: "com.klang.aggregate",
            masterUID: outputUID,           // real hardware = clock master
            subDeviceUIDs: [outputUID, inputUID],
            driftUIDs: [inputUID])          // drift-correct the virtual input
    }
}
