public struct AudioDeviceInfo: Equatable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let isInput: Bool
    public let isOutput: Bool
    public let isVirtual: Bool
    public let supportedRates: [Double]

    public init(id: UInt32, uid: String, name: String, isInput: Bool,
                isOutput: Bool, isVirtual: Bool, supportedRates: [Double]) {
        self.id = id; self.uid = uid; self.name = name
        self.isInput = isInput; self.isOutput = isOutput
        self.isVirtual = isVirtual; self.supportedRates = supportedRates
    }
}
