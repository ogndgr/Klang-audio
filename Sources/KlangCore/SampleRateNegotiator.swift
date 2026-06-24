public enum SampleRateNegotiator {
    public static func bestCommonRate(preferred: Double, _ a: [Double], _ b: [Double]) -> Double? {
        let common = Set(a).intersection(Set(b))
        if common.contains(preferred) { return preferred }
        return common.max()
    }
}
