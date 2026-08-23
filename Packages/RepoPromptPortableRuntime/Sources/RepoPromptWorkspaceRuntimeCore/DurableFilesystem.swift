import Foundation
import RepoPromptRuntimeModel

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

public enum DurableFilesystemFaultPoint: String, Sendable {
    case temporaryCreated
    case contentsWritten
    case temporarySynchronized
    case destinationRenamed
    case directorySynchronized
}

public struct DurableFilesystemFaultInjector: Sendable {
    private let operation: @Sendable (DurableFilesystemFaultPoint) throws -> Void

    public init(_ operation: @escaping @Sendable (DurableFilesystemFaultPoint) throws -> Void) {
        self.operation = operation
    }

    public func hit(_ point: DurableFilesystemFaultPoint) throws {
        try operation(point)
    }

    public static let none = DurableFilesystemFaultInjector { _ in }
}

public enum DurableFilesystem {
    public static func standardizedContainedPath(root: String, candidate: String) throws -> String {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL
        let parent = candidateURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: parent).appendingPathComponent(candidateURL.lastPathComponent).standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolved.hasPrefix(prefix), resolved != rootPath else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Service-owned path escaped its configured root")
        }
        return resolved
    }

    public static func publish(data: Data, temporary: URL, destination: URL, mode: Int16 = 0o600, faultInjector: DurableFilesystemFaultInjector = .none) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: temporary.path) { try manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: mode)]) else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to create service-owned staging file")
        }
        do {
            try faultInjector.hit(.temporaryCreated)
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
                try faultInjector.hit(.contentsWritten)
                try handle.synchronize()
                try faultInjector.hit(.temporarySynchronized)
            }
            if manager.fileExists(atPath: destination.path) {
                throw ServiceAPIError(code: .worktreeConflict, message: "Service-owned destination already exists")
            }
            try manager.moveItem(at: temporary, to: destination)
            try faultInjector.hit(.destinationRenamed)
            try fsyncDirectory(destination.deletingLastPathComponent().path)
            try faultInjector.hit(.directorySynchronized)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    public static func fsyncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to open service-owned directory for synchronization")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to synchronize service-owned directory")
        }
    }
}
