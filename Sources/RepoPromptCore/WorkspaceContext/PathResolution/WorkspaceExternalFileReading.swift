import Foundation

package protocol WorkspaceExternalFileReading: Sendable {
    func resolveRegularFile(
        atAbsolutePath path: String,
        allowedDirectories: [AlwaysReadableDirectory]
    ) throws -> String?

    func resolveDirectory(
        atAbsolutePath path: String,
        allowedDirectories: [AlwaysReadableDirectory]
    ) throws -> String?

    func readRegularFile(
        atAbsolutePath path: String,
        allowedDirectories: [AlwaysReadableDirectory]
    ) throws -> Data
}

package enum WorkspaceExternalFileReaderProvider {
    package typealias Factory = @Sendable () -> any WorkspaceExternalFileReading

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var factory: Factory = { UnavailableWorkspaceExternalFileReader() }
    }

    private static let state = State()

    package static func install(_ factory: @escaping Factory) {
        state.lock.lock()
        state.factory = factory
        state.lock.unlock()
    }

    package static func makeReader() -> any WorkspaceExternalFileReading {
        state.lock.lock()
        let factory = state.factory
        state.lock.unlock()
        return factory()
    }
}

package struct UnavailableWorkspaceExternalFileReader: WorkspaceExternalFileReading {
    package init() {}

    package func resolveRegularFile(
        atAbsolutePath _: String,
        allowedDirectories _: [AlwaysReadableDirectory]
    ) throws -> String? {
        nil
    }

    package func resolveDirectory(
        atAbsolutePath _: String,
        allowedDirectories _: [AlwaysReadableDirectory]
    ) throws -> String? {
        nil
    }

    package func readRegularFile(
        atAbsolutePath path: String,
        allowedDirectories _: [AlwaysReadableDirectory]
    ) throws -> Data {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
    }
}
