import Foundation

/// The persistence codec needs model identity, never provider discovery or execution.
/// App composition must install its existing Cursor catalog projection before reading pins.
package enum SettingsModelIdentityPolicy {
    private static let cursorPolicy = CursorPolicy()

    package static func installCursorCanonicalizer(_ canonicalize: @escaping @Sendable (String) -> String) {
        cursorPolicy.install(canonicalize)
    }

    static func canonicalCursorModelRaw(_ raw: String) -> String {
        cursorPolicy.canonicalize(raw)
    }

    /// Codable entry points are not actor-isolated. Synchronization protects only the
    /// injected policy reference; catalog work is always invoked outside the lock.
    private final class CursorPolicy: @unchecked Sendable {
        private let lock = NSLock()
        private var canonicalizer: (@Sendable (String) -> String)?

        func install(_ canonicalize: @escaping @Sendable (String) -> String) {
            lock.lock()
            canonicalizer = canonicalize
            lock.unlock()
        }

        func canonicalize(_ raw: String) -> String {
            lock.lock()
            let canonicalize = canonicalizer
            lock.unlock()
            guard let canonicalize else {
                preconditionFailure("Install the app Cursor identity policy before reading settings model pins")
            }
            return canonicalize(raw)
        }
    }
}
