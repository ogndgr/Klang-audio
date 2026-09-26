public struct AudioDeviceInfo: Equatable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let isInput: Bool
    public let isOutput: Bool
    public let isVirtual: Bool
    public let supportedRates: [Double]
    /// Number of input channels the device exposes. Needed to locate BlackHole's
    /// channels inside a duplex aggregate: on a combo (input+output) target device,
    /// BlackHole's inputs follow the target's own input channels in the channel list.
    public let inputChannels: Int

    public init(id: UInt32, uid: String, name: String, isInput: Bool,
                isOutput: Bool, isVirtual: Bool, supportedRates: [Double],
                inputChannels: Int = 0) {
        self.id = id; self.uid = uid; self.name = name
        self.isInput = isInput; self.isOutput = isOutput
        self.isVirtual = isVirtual; self.supportedRates = supportedRates
        self.inputChannels = inputChannels
    }
}
