import Foundation

/// A narrow `NSLock` wrapper for lock owners whose caller closures have been
/// explicitly reviewed. DEBUG builds trap before trying to acquire the same lock
/// recursively on one thread; release builds retain `NSLock` behavior.
final class SameThreadReentryCheckedLock: @unchecked Sendable {
    private let underlyingLock = NSLock()

    #if DEBUG
        private let ownershipKey = "RepoPrompt.SameThreadReentryCheckedLock.\(UUID().uuidString)"
    #endif

    func lock() {
        #if DEBUG
            let threadDictionary = Thread.current.threadDictionary
            precondition(
                threadDictionary.object(forKey: ownershipKey) == nil,
                "Same-thread reentry attempted while a reviewed non-recursive lock is held."
            )
        #endif
        underlyingLock.lock()
        #if DEBUG
            Thread.current.threadDictionary[ownershipKey] = true
        #endif
    }

    func unlock() {
        #if DEBUG
            let threadDictionary = Thread.current.threadDictionary
            precondition(
                threadDictionary.object(forKey: ownershipKey) != nil,
                "Unlock attempted without same-thread ownership of a reviewed non-recursive lock."
            )
            threadDictionary.removeObject(forKey: ownershipKey)
        #endif
        underlyingLock.unlock()
    }
}
