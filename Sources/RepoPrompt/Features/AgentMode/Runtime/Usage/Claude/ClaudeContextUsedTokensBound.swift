enum ClaudeContextUsedTokensBound {
    /// Unknown-window garbage guard: about 10× the largest shipped context window (1M),
    /// so any future shipped-window bump should revisit this ceiling.
    static let absoluteUnknownWindowCeiling = 10_000_000

    static func normalizedReading(_ reading: Int?, canonicalWindow: Int?) -> Int? {
        guard let reading, reading > 0 else { return nil }
        let bound = canonicalWindow ?? absoluteUnknownWindowCeiling
        guard reading <= bound else { return nil }
        return reading
    }
}
