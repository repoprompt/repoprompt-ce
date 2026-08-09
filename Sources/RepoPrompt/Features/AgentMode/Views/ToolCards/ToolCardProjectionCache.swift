import Foundation

/// Bounded memoization fence for deterministic tool-card presentation
/// projections derived from immutable transcript JSON payloads.
///
/// SwiftUI re-evaluates tool-card `body` frequently while a transcript
/// streams. Decoding completed tool-result JSON and classifying it into
/// presentation values (DTOs, structured objects, card status) is
/// deterministic for a given payload, so this cache performs each derivation
/// once per unique input revision and reuses the immutable value across body
/// recomputations.
///
/// This cache is not an authority. Canonical transcript items remain the only
/// source of truth; entries are keyed purely by input content, so a changed
/// payload (for example a new streaming revision) naturally misses and is
/// derived fresh. Storage is bounded: when the entry count reaches
/// `maxEntryCount` the map is dropped wholesale and rebuilt on demand — the
/// same policy used by `BashToolResultParser.Cache` and
/// `AgentToolResultProcessingContext`.
final class ToolCardProjectionCache: @unchecked Sendable {
    static let shared = ToolCardProjectionCache()

    static let maxEntryCount = 512

    private struct Key: Hashable {
        let kind: ObjectIdentifier
        let variant: String
        let primary: String
        let secondary: String?
    }

    private enum Entry {
        case value(Any)
        case missing
    }

    #if DEBUG
        struct Metrics: Equatable {
            var hitCount = 0
            var missCount = 0
            var evictionCount = 0
        }

        private var metrics = Metrics()
    #endif

    private let lock = NSLock()
    private var storage: [Key: Entry] = [:]

    /// Returns the memoized projection for `(Value.self, variant, primary,
    /// secondary)`, computing it once per unique input. `compute` must be a
    /// pure function of the key inputs. A `nil` computed value is memoized as
    /// missing so failed derivations are not retried on every body evaluation.
    ///
    /// Inputs with a `nil` or empty `primary` are not cached; `compute` runs
    /// directly (it is expected to be trivial for empty payloads).
    func projection<Value>(
        _ valueType: Value.Type,
        variant: String,
        primary: String?,
        secondary: String? = nil,
        compute: () -> Value?
    ) -> Value? {
        guard let primary, !primary.isEmpty else {
            return compute()
        }
        let key = Key(
            kind: ObjectIdentifier(valueType),
            variant: variant,
            primary: primary,
            secondary: secondary
        )
        lock.lock()
        if let cached = storage[key] {
            #if DEBUG
                metrics.hitCount += 1
            #endif
            lock.unlock()
            switch cached {
            case let .value(value):
                return value as? Value
            case .missing:
                return nil
            }
        }
        #if DEBUG
            metrics.missCount += 1
        #endif
        lock.unlock()

        let value = compute()

        lock.lock()
        if storage.count >= Self.maxEntryCount {
            #if DEBUG
                metrics.evictionCount += 1
            #endif
            storage.removeAll(keepingCapacity: true)
        }
        storage[key] = value.map(Entry.value) ?? .missing
        lock.unlock()
        return value
    }

    #if DEBUG
        func metricsSnapshot() -> Metrics {
            lock.lock()
            defer { lock.unlock() }
            return metrics
        }

        var entryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.count
        }
    #endif
}
