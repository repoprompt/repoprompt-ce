import Foundation

/// Provides the immutable bundled profile snapshot used by routing candidate capture.
/// Remote activation and mutable publication are intentionally not part of this store.
@MainActor
final class RoutingProfileStore {
    private let bundledSnapshot: RoutingModelProfileSnapshot

    init(bundledSnapshot: RoutingModelProfileSnapshot = .bundled) {
        self.bundledSnapshot = bundledSnapshot
    }

    func snapshot() -> RoutingModelProfileSnapshot {
        bundledSnapshot
    }
}
