import Foundation

enum WorkspaceCodemapBindingEngineProviderError: Error, Equatable {
    case unconfigured
}

/// Lazily creates the single binding engine owned by one artifact runtime.
///
/// The provider is intentionally inert until a caller requests the engine. Both successful
/// construction and failure are memoized so concurrent callers observe one stable result.
final class WorkspaceCodemapBindingEngineProvider: @unchecked Sendable {
    typealias Factory = @Sendable (CodeMapArtifactRuntime) throws -> WorkspaceCodemapBindingEngine

    private enum State {
        case pending(Factory)
        case resolved(Result<WorkspaceCodemapBindingEngine, Error>)
    }

    static let unconfiguredFactory: Factory = { _ in
        throw WorkspaceCodemapBindingEngineProviderError.unconfigured
    }

    private let lock = NSLock()
    private var state: State

    init(factory: @escaping Factory = unconfiguredFactory) {
        state = .pending(factory)
    }

    func engine(for runtime: CodeMapArtifactRuntime) throws -> WorkspaceCodemapBindingEngine {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case let .resolved(result):
            return try result.get()
        case let .pending(factory):
            let result: Result<WorkspaceCodemapBindingEngine, Error>
            do {
                result = try .success(factory(runtime))
            } catch {
                result = .failure(error)
            }
            state = .resolved(result)
            return try result.get()
        }
    }
}
