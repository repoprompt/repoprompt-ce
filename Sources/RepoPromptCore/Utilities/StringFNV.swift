import RepoPromptC

package extension String {
    /// 64-bit FNV-1a hash used for stable content cache identity.
    @inline(__always)
    func fnv1a64() -> UInt64 {
        withCString { repo_fnv1a64($0) }
    }
}
