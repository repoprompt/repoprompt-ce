package enum TokenEstimator {
    @inline(__always)
    package static func estimateTokens(for text: String) -> Int {
        let bytes = text.utf8.count
        return Int((Double(bytes) / 4.0) * 1.05)
    }
}
