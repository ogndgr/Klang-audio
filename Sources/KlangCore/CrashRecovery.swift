public enum CrashRecovery {
    public static func shouldRestoreDefaultOutput(currentDefaultIsBlackHole: Bool,
                                                  engineRunning: Bool) -> Bool {
        currentDefaultIsBlackHole && !engineRunning
    }
}
