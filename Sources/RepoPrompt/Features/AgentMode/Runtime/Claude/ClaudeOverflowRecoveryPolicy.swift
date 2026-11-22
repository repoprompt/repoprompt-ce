enum ClaudeOverflowRecoveryPolicy {
    /// With no counts in the refusal itself, only a vouched near-limit context qualifies.
    static func historyIsNearLimit(used: Int?, window: Int?) -> Bool {
        guard let used, let window, window > 0, used > 0 else { return false }
        return used >= window - window / 10
    }

    /// Require at least 20% free; the compact command's own pre_tokens is not headroom.
    static func hasHeadroom(postTokens: Int?, window: Int?) -> Bool {
        guard let postTokens, let window, window > 0, postTokens > 0 else { return false }
        return postTokens <= window - (window - 1) / 5 - 1
    }
}
