import Foundation
import RepoPromptRuntimeModel
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum PinnedFilesystemMutationError: Error, Sendable {
    case operationFailed(Int32)
}

public protocol PinnedFilesystemMutationPort: Sendable {
    func removeTree(parentDescriptor: Int32, relativePath: String) throws
    func rename(parentDescriptor: Int32, source: String, destination: String) throws
}

/// Descriptor-relative, no-follow filesystem mutations shared by Darwin and Linux.
public struct POSIXPinnedFilesystemMutationPort: PinnedFilesystemMutationPort {
    public init() {}

    public func removeTree(parentDescriptor: Int32, relativePath: String) throws {
        var components = relativePath.split(separator: "/").map(String.init)
        guard let leaf = components.popLast() else { throw PinnedFilesystemMutationError.operationFailed(EINVAL) }
        var parent = dup(parentDescriptor)
        guard parent >= 0 else { throw PinnedFilesystemMutationError.operationFailed(errno) }
        defer { close(parent) }
        for component in components {
            let next = component.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw PinnedFilesystemMutationError.operationFailed(errno) }
            close(parent)
            parent = next
        }
        try removeEntry(parentDescriptor: parent, name: leaf)
    }

    public func rename(parentDescriptor: Int32, source: String, destination: String) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                renameat(parentDescriptor, sourcePointer, parentDescriptor, destinationPointer)
            }
        }
        guard result == 0 else { throw PinnedFilesystemMutationError.operationFailed(errno) }
    }

    private func removeEntry(parentDescriptor: Int32, name: String) throws {
        var status = stat()
        let statResult = name.withCString { fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }
        if statResult != 0 {
            if errno == ENOENT { return }
            throw PinnedFilesystemMutationError.operationFailed(errno)
        }
        let isDirectory = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        if isDirectory {
            let child = name.withCString { openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard child >= 0 else { throw PinnedFilesystemMutationError.operationFailed(errno) }
            defer { close(child) }
            let duplicate = dup(child)
            guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }
                throw PinnedFilesystemMutationError.operationFailed(errno)
            }
            var names: [String] = []
            while let entry = readdir(directory) {
                let entryName = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                    String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
                }
                if entryName != ".", entryName != ".." { names.append(entryName) }
            }
            closedir(directory)
            for childName in names {
                try removeEntry(parentDescriptor: child, name: childName)
            }
            let result = name.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            guard result == 0 || errno == ENOENT else { throw PinnedFilesystemMutationError.operationFailed(errno) }
        } else {
            let result = name.withCString { unlinkat(parentDescriptor, $0, 0) }
            guard result == 0 || errno == ENOENT else { throw PinnedFilesystemMutationError.operationFailed(errno) }
        }
    }
}

public final class PinnedFilesystemRoot: @unchecked Sendable {
    public let path: String
    public let identity: String
    private let descriptor: Int32
    private let mutations: any PinnedFilesystemMutationPort

    public init(
        path: String,
        identity: String,
        mutations: any PinnedFilesystemMutationPort = POSIXPinnedFilesystemMutationPort()
    ) throws {
        let descriptor = try Self.openAbsoluteDirectoryChain(path, createMissing: false, permissions: 0)
        var status = stat()
        let identityParts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard fstat(descriptor, &status) == 0,
              identityParts.count >= 2,
              identityParts[0] == Substring(String(status.st_dev)),
              identityParts[1] == Substring(String(status.st_ino))
        else {
            close(descriptor)
            throw ServiceAPIError(code: .rootUnauthorized, message: "Configured filesystem root identity changed while being pinned")
        }
        self.path = path
        self.identity = identity
        self.descriptor = descriptor
        self.mutations = mutations
    }

    private init(
        path: String,
        descriptor: Int32,
        mutations: any PinnedFilesystemMutationPort
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem directory identity is unavailable")
        }
        self.path = path
        identity = "\(status.st_dev):\(status.st_ino)"
        self.descriptor = descriptor
        self.mutations = mutations
    }

    deinit {
        close(descriptor)
    }

    public static func pinExisting(
        at path: String,
        mutations: any PinnedFilesystemMutationPort = POSIXPinnedFilesystemMutationPort()
    ) throws -> PinnedFilesystemRoot {
        let standardized = try standardizedAbsolutePath(path)
        let descriptor = try openAbsoluteDirectoryChain(standardized, createMissing: false, permissions: 0)
        return try PinnedFilesystemRoot(path: standardized, descriptor: descriptor, mutations: mutations)
    }

    public static func createDirectoryTreeAndPin(
        at path: String,
        permissions: mode_t = 0o755,
        mutations: any PinnedFilesystemMutationPort = POSIXPinnedFilesystemMutationPort()
    ) throws -> PinnedFilesystemRoot {
        let standardized = try standardizedAbsolutePath(path)
        let descriptor = try openAbsoluteDirectoryChain(standardized, createMissing: true, permissions: permissions)
        return try PinnedFilesystemRoot(path: standardized, descriptor: descriptor, mutations: mutations)
    }

    public static func validateDirectoryChain(at path: String) throws {
        let standardized = try standardizedAbsolutePath(path)
        let descriptor = try openAbsoluteDirectoryChain(standardized, createMissing: false, permissions: 0)
        close(descriptor)
    }

    public func validateReachableIdentity() throws {
        let current = try Self.openAbsoluteDirectoryChain(path, createMissing: false, permissions: 0)
        defer { close(current) }
        var expectedStatus = stat()
        var currentStatus = stat()
        guard fstat(descriptor, &expectedStatus) == 0,
              fstat(current, &currentStatus) == 0,
              expectedStatus.st_dev == currentStatus.st_dev,
              expectedStatus.st_ino == currentStatus.st_ino
        else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem root or an ancestor changed")
        }
    }

    public func createDirectory(at candidate: String, permissions: mode_t = 0o755) throws -> PinnedFilesystemRoot {
        let relative = try relativePath(for: candidate)
        guard let child = try openRelativeDirectory(relative, createMissing: true, permissions: permissions, missingIsNil: false) else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem directory was not created")
        }
        return try PinnedFilesystemRoot(
            path: URL(fileURLWithPath: candidate).standardized.path,
            descriptor: child,
            mutations: mutations
        )
    }

    public func directoryIfExists(at candidate: String) throws -> PinnedFilesystemRoot? {
        let relative = try relativePath(for: candidate)
        guard let child = try openRelativeDirectory(relative, createMissing: false, permissions: 0, missingIsNil: true) else { return nil }
        return try PinnedFilesystemRoot(
            path: URL(fileURLWithPath: candidate).standardized.path,
            descriptor: child,
            mutations: mutations
        )
    }

    public func directoryEntryNames() throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem directory could not be enumerated")
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    public func writeFile(named name: String, data: Data, permissions: mode_t = 0o444) throws {
        try Self.validateComponent(name)
        let file = name.withCString { openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions) }
        guard file >= 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem file could not be created")
        }
        defer { close(file) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(file, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem file write failed")
                }
                offset += count
            }
        }
        guard fchmod(file, permissions) == 0, fsync(file) == 0, fsync(descriptor) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem file could not be synchronized")
        }
    }

    public func readFile(named name: String, maximumBytes: Int = 1_048_576) throws -> Data {
        try Self.validateComponent(name)
        let file = name.withCString { openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard file >= 0 else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem file could not be opened")
        }
        defer { close(file) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(file, &buffer, buffer.count)
            guard count >= 0 else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem file could not be read")
            }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem file exceeded its limit")
            }
            data.append(buffer, count: count)
        }
        return data
    }

    public func createSymbolicLink(named name: String, destination: String) throws {
        try Self.validateComponent(name)
        let result = destination.withCString { target in
            name.withCString { link in symlinkat(target, descriptor, link) }
        }
        guard result == 0, fsync(descriptor) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem route could not be created")
        }
    }

    public func symbolicLinkDestination(named name: String) throws -> String {
        try Self.validateComponent(name)
        var buffer = [CChar](repeating: 0, count: 65536)
        let count = name.withCString { readlinkat(descriptor, $0, &buffer, buffer.count - 1) }
        guard count >= 0, count < buffer.count - 1 else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem route could not be read")
        }
        let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func setPermissions(_ permissions: mode_t) throws {
        guard fchmod(descriptor, permissions) == 0, fsync(descriptor) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem directory permissions could not be synchronized")
        }
    }

    public func removeTree(at candidate: String) throws {
        let relative = try relativePath(for: candidate)
        do {
            try mutations.removeTree(parentDescriptor: descriptor, relativePath: relative)
        } catch {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem cleanup was rejected")
        }
        guard fsync(descriptor) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem cleanup could not be synchronized")
        }
    }

    public func moveAtomically(from source: String, to destination: String) throws {
        let sourceRelative = try relativePath(for: source)
        let destinationRelative = try relativePath(for: destination)
        do {
            try mutations.rename(
                parentDescriptor: descriptor,
                source: sourceRelative,
                destination: destinationRelative
            )
        } catch {
            throw ServiceAPIError(code: .worktreeConflict, message: "Pinned filesystem promotion failed")
        }
        guard fsync(descriptor) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem promotion could not be synchronized")
        }
    }

    private static func standardizedAbsolutePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem root must be an absolute path")
        }
        let standardized = URL(fileURLWithPath: path).standardized.path
        guard standardized == path else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem root path is not canonical")
        }
        return standardized
    }

    private static func openAbsoluteDirectoryChain(_ path: String, createMissing: Bool, permissions: mode_t) throws -> Int32 {
        let standardized = try standardizedAbsolutePath(path)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Filesystem root could not be opened")
        }
        for component in URL(fileURLWithPath: standardized).pathComponents where component != "/" {
            do {
                try validateComponent(component)
            } catch {
                close(current)
                throw error
            }
            if createMissing {
                let result = component.withCString { mkdirat(current, $0, permissions) }
                if result != 0, errno != EEXIST {
                    close(current)
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem directory could not be created")
                }
            }
            let next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else {
                close(current)
                throw ServiceAPIError(
                    code: .rootUnauthorized,
                    message: "Filesystem directory chain contains a symbolic link or non-directory at \(component) in \(standardized)"
                )
            }
            close(current)
            current = next
        }
        return current
    }

    private func openRelativeDirectory(
        _ relative: String,
        createMissing: Bool,
        permissions: mode_t,
        missingIsNil: Bool
    ) throws -> Int32? {
        var current = dup(descriptor)
        guard current >= 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem descriptor could not be duplicated")
        }
        for component in relative.split(separator: "/").map(String.init) {
            if createMissing {
                let result = component.withCString { mkdirat(current, $0, permissions) }
                if result != 0, errno != EEXIST {
                    close(current)
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Pinned filesystem child directory could not be created")
                }
            }
            let next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else {
                let missing = errno == ENOENT
                close(current)
                if missing, missingIsNil { return nil }
                throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem child directory is missing or unsafe")
            }
            close(current)
            current = next
        }
        return current
    }

    private static func validateComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.utf8.contains(0)
        else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Pinned filesystem path component is invalid")
        }
    }

    private func relativePath(for candidate: String) throws -> String {
        let standardized = URL(fileURLWithPath: candidate).standardized.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        guard standardized.hasPrefix(prefix) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Filesystem path escaped its pinned root")
        }
        let relative = String(standardized.dropFirst(prefix.count))
        guard !relative.isEmpty else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Filesystem path cannot name the pinned root itself")
        }
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            try Self.validateComponent(String(component))
        }
        return relative
    }
}

public struct CanonicalRoot: Hashable, Sendable {
    public let snapshot: ProjectRootSnapshot
    public let filesystemIdentity: String
    public init(snapshot: ProjectRootSnapshot, filesystemIdentity: String) {
        self.snapshot = snapshot
        self.filesystemIdentity = filesystemIdentity
    }
}

public protocol FilesystemAuthorityPort: Sendable {
    func canonicalizeRoot(_ path: String) throws -> (path: String, identity: String, isDirectory: Bool)
    func contains(root: String, candidate: String) throws -> Bool
}

public struct LocalFilesystemAuthority: FilesystemAuthorityPort {
    public init() {}

    public func canonicalizeRoot(_ path: String) throws -> (path: String, identity: String, isDirectory: Bool) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolvedPointer = standardized.withCString({ realpath($0, nil) }) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project root must be an existing directory")
        }
        defer { free(resolvedPointer) }
        let resolvedBytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(resolvedPointer).assumingMemoryBound(to: UInt8.self),
            count: strlen(resolvedPointer)
        )
        let canonicalPath = String(decoding: resolvedBytes, as: UTF8.self)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project root must be an existing directory")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: canonicalPath)
        // Preserve the persisted identity contract used before extraction.
        // Birth-time fencing is a semantic migration and is deferred from PR 2.
        let identity = [attributes[.systemNumber], attributes[.systemFileNumber]]
            .compactMap(\.self)
            .map(String.init(describing:))
            .joined(separator: ":")
        return (canonicalPath, identity, true)
    }

    public func contains(root: String, candidate: String) throws -> Bool {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(prefix)
    }
}

public actor ProjectAuthority {
    public let projectID: UUID
    private var snapshotValue: ProjectSnapshot
    private let rootsByID: [UUID: CanonicalRoot]

    public init(snapshot: ProjectSnapshot, roots: [CanonicalRoot]) {
        projectID = snapshot.projectID
        snapshotValue = snapshot
        rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.snapshot.rootID, $0) })
    }

    public func snapshot() -> ProjectSnapshot {
        snapshotValue
    }

    public func root(rootID: UUID) throws -> CanonicalRoot {
        guard let root = rootsByID[rootID] else { throw ServiceAPIError(code: .rootUnauthorized, message: "Unknown project root") }
        return root
    }

    public func roots() -> [CanonicalRoot] {
        rootsByID.values.sorted { $0.snapshot.logicalName < $1.snapshot.logicalName }
    }

    public func authorize(rootID: UUID, logicalPath: String, filesystem: any FilesystemAuthorityPort) throws -> String {
        guard let root = rootsByID[rootID] else { throw ServiceAPIError(code: .rootUnauthorized, message: "Unknown project root") }
        guard !logicalPath.hasPrefix("/") else { throw ServiceAPIError(code: .rootUnauthorized, message: "Logical paths must be relative") }
        let currentRoot = try filesystem.canonicalizeRoot(root.snapshot.canonicalPath)
        guard currentRoot.path == root.snapshot.canonicalPath, currentRoot.identity == root.filesystemIdentity else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Authorized project root identity changed")
        }
        let candidate = logicalPath.isEmpty
            ? root.snapshot.canonicalPath
            : URL(fileURLWithPath: root.snapshot.canonicalPath).appendingPathComponent(logicalPath).path
        guard try filesystem.contains(root: root.snapshot.canonicalPath, candidate: candidate) else { throw ServiceAPIError(code: .rootUnauthorized, message: "Path escapes the authorized root") }
        return URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public actor ProjectRuntimeSupervisor {
    private var projects: [UUID: ProjectAuthority] = [:]

    public init() {}
    public func install(_ project: ProjectAuthority) async {
        projects[project.projectID] = project
    }

    public func remove(projectID: UUID) {
        projects[projectID] = nil
    }

    public func authority(projectID: UUID) throws -> ProjectAuthority {
        guard let project = projects[projectID] else { throw ServiceAPIError(code: .notFound, message: "Project not found") }
        return project
    }

    public func snapshots() async -> [ProjectSnapshot] {
        var result: [ProjectSnapshot] = []
        for project in projects.values {
            await result.append(project.snapshot())
        }
        return result.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
    }
}
