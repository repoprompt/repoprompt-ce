import Darwin
import Foundation

enum HeadlessStateFileSecurity {
    typealias ParentDirectoryOpenedHook = (Int32) throws -> Void

    static let directoryMode: mode_t = S_IRWXU
    static let fileMode: mode_t = S_IRUSR | S_IWUSR

    static func ensurePrivateDirectory(at url: URL, fileManager _: FileManager = .default) throws {
        let descriptor = try openPrivateDirectory(at: url)
        Darwin.close(descriptor)
    }

    static func ensurePrivateDirectory(
        at url: URL,
        stateRoot: URL,
        fileManager _: FileManager = .default
    ) throws {
        let descriptor = try openPrivateDirectory(at: url, stateRoot: stateRoot)
        Darwin.close(descriptor)
    }

    static func readPrivateFileIfPresent(
        at url: URL,
        stateRoot: URL,
        parentDirectoryOpenedHook: ParentDirectoryOpenedHook? = nil
    ) throws -> Data? {
        let parentDescriptor = try openPrivateDirectory(at: url.deletingLastPathComponent(), stateRoot: stateRoot)
        defer { Darwin.close(parentDescriptor) }
        try parentDirectoryOpenedHook?(parentDescriptor)
        let descriptor = try openLeaf(
            url.lastPathComponent,
            relativeTo: parentDescriptor,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
            path: url.path,
            allowMissing: true
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        try validateOpenedDescriptor(
            descriptor,
            path: url.path,
            expectedKind: S_IFREG,
            requiredMode: fileMode
        )
        return try readAll(from: descriptor, path: url.path)
    }

    static func writePrivateFile(
        _ data: Data,
        to url: URL,
        stateRoot: URL,
        fileManager _: FileManager = .default,
        parentDirectoryOpenedHook: ParentDirectoryOpenedHook? = nil
    ) throws {
        let parentDescriptor = try openPrivateDirectory(at: url.deletingLastPathComponent(), stateRoot: stateRoot)
        defer { Darwin.close(parentDescriptor) }
        try parentDirectoryOpenedHook?(parentDescriptor)
        try validateExistingPrivateFileIfPresent(
            named: url.lastPathComponent,
            relativeTo: parentDescriptor,
            path: url.path
        )

        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString { pointer in
            Darwin.openat(
                parentDescriptor,
                pointer,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                fileMode
            )
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "create private state file", path: url.path, errorNumber: errno)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                temporaryName.withCString { pointer in _ = Darwin.unlinkat(parentDescriptor, pointer, 0) }
            }
        }

        try validateOpenedDescriptor(
            descriptor,
            path: url.path,
            expectedKind: S_IFREG,
            requiredMode: fileMode
        )
        try writeAll(data, to: descriptor, path: url.path)
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(operation: "sync private state file", path: url.path, errorNumber: errno)
        }
        let renameResult = temporaryName.withCString { temporaryPointer in
            url.lastPathComponent.withCString { targetPointer in
                Darwin.renameat(parentDescriptor, temporaryPointer, parentDescriptor, targetPointer)
            }
        }
        guard renameResult == 0 else {
            throw posixError(operation: "replace private state file", path: url.path, errorNumber: errno)
        }
        shouldRemoveTemporaryFile = false
        try validateExistingPrivateFileIfPresent(
            named: url.lastPathComponent,
            relativeTo: parentDescriptor,
            path: url.path,
            requirePresent: true
        )
    }

    static func openPrivateLockFile(
        at url: URL,
        stateRoot: URL,
        fileManager _: FileManager = .default,
        parentDirectoryOpenedHook: ParentDirectoryOpenedHook? = nil
    ) throws -> Int32 {
        let parentDescriptor = try openPrivateDirectory(at: url.deletingLastPathComponent(), stateRoot: stateRoot)
        defer { Darwin.close(parentDescriptor) }
        try parentDirectoryOpenedHook?(parentDescriptor)
        let descriptor = url.lastPathComponent.withCString { pointer in
            Darwin.openat(
                parentDescriptor,
                pointer,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                fileMode
            )
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open private lock file", path: url.path, errorNumber: errno)
        }
        do {
            try validateOpenedDescriptor(
                descriptor,
                path: url.path,
                expectedKind: S_IFREG,
                requiredMode: fileMode
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func validateOpenedDescriptor(
        _ descriptor: Int32,
        path: String,
        expectedKind: mode_t,
        requiredMode: mode_t,
        expectedOwner: uid_t = Darwin.geteuid()
    ) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError(operation: "inspect private state path", path: path, errorNumber: errno)
        }
        guard status.st_uid == expectedOwner else {
            throw HeadlessCommandError(
                "Private state path has unexpected owner uid \(status.st_uid); expected \(expectedOwner): \(path)",
                exitCode: 2
            )
        }
        guard status.st_mode & S_IFMT == expectedKind else {
            throw HeadlessCommandError("Private state path has an unsafe file type: \(path)", exitCode: 2)
        }
        guard status.st_nlink == 1 || expectedKind == S_IFDIR else {
            throw HeadlessCommandError("Private state file must not have multiple hard links: \(path)", exitCode: 2)
        }
        guard Darwin.fchmod(descriptor, requiredMode) == 0 else {
            throw posixError(operation: "enforce private permissions", path: path, errorNumber: errno)
        }
    }

    private static func openPrivateDirectory(at url: URL, stateRoot: URL) throws -> Int32 {
        let rootPath = stateRoot.path
        let targetPath = url.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw HeadlessCommandError("Private state path escapes its state root '\(rootPath)': \(targetPath)", exitCode: 2)
        }

        var descriptor = try openPrivateDirectory(at: stateRoot)
        if targetPath == rootPath { return descriptor }
        let suffix = String(targetPath.dropFirst(rootPath.count + 1))
        do {
            for component in suffix.split(separator: "/").map(String.init) {
                let mkdirResult = component.withCString { pointer in
                    Darwin.mkdirat(descriptor, pointer, directoryMode)
                }
                if mkdirResult != 0, errno != EEXIST {
                    throw posixError(operation: "create private state directory", path: targetPath, errorNumber: errno)
                }
                let nextDescriptor = try openLeaf(
                    component,
                    relativeTo: descriptor,
                    flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                    path: targetPath,
                    allowMissing: false
                )
                try validateOpenedDescriptor(
                    nextDescriptor,
                    path: targetPath,
                    expectedKind: S_IFDIR,
                    requiredMode: directoryMode
                )
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openPrivateDirectory(at url: URL) throws -> Int32 {
        let directoryURL = url
        guard directoryURL.path.hasPrefix("/"), !directoryURL.lastPathComponent.isEmpty else {
            throw HeadlessCommandError("Private state directory must be an absolute non-root path: \(url.path)", exitCode: 2)
        }
        let parentDescriptor = try openDirectoryPathCreatingMissing(directoryURL.deletingLastPathComponent().path)
        defer { Darwin.close(parentDescriptor) }

        let name = directoryURL.lastPathComponent
        let mkdirResult = name.withCString { pointer in
            Darwin.mkdirat(parentDescriptor, pointer, directoryMode)
        }
        if mkdirResult != 0, errno != EEXIST {
            throw posixError(operation: "create private state directory", path: directoryURL.path, errorNumber: errno)
        }
        let descriptor = try openLeaf(
            name,
            relativeTo: parentDescriptor,
            flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            path: directoryURL.path,
            allowMissing: false
        )
        do {
            try validateOpenedDescriptor(
                descriptor,
                path: directoryURL.path,
                expectedKind: S_IFDIR,
                requiredMode: directoryMode
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openDirectoryPathCreatingMissing(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else {
            throw HeadlessCommandError("Private state directory must be absolute: \(path)", exitCode: 2)
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(operation: "open filesystem root", path: path, errorNumber: errno)
        }
        do {
            for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
                let mkdirResult = component.withCString { pointer in
                    Darwin.mkdirat(descriptor, pointer, directoryMode)
                }
                if mkdirResult != 0, errno != EEXIST {
                    throw posixError(operation: "create private state ancestor", path: path, errorNumber: errno)
                }
                let created = mkdirResult == 0
                let nextDescriptor = try openLeaf(
                    component,
                    relativeTo: descriptor,
                    flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
                    path: path,
                    allowMissing: false
                )
                if created {
                    try validateOpenedDescriptor(
                        nextDescriptor,
                        path: path,
                        expectedKind: S_IFDIR,
                        requiredMode: directoryMode
                    )
                }
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openLeaf(
        _ name: String,
        relativeTo parentDescriptor: Int32,
        flags: Int32,
        path: String,
        allowMissing: Bool
    ) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0) else {
            throw HeadlessCommandError("Private state path contains an invalid component: \(path)", exitCode: 2)
        }
        let descriptor = name.withCString { pointer in
            Darwin.openat(parentDescriptor, pointer, flags)
        }
        if descriptor < 0, allowMissing, errno == ENOENT {
            return -1
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open private state path", path: path, errorNumber: errno)
        }
        return descriptor
    }

    private static func validateExistingPrivateFileIfPresent(
        named name: String,
        relativeTo parentDescriptor: Int32,
        path: String,
        requirePresent: Bool = false
    ) throws {
        let descriptor = try openLeaf(
            name,
            relativeTo: parentDescriptor,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
            path: path,
            allowMissing: !requirePresent
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        try validateOpenedDescriptor(
            descriptor,
            path: path,
            expectedKind: S_IFREG,
            requiredMode: fileMode
        )
    }

    private static func readAll(from descriptor: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(operation: "read private state file", path: path, errorNumber: errno)
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(operation: "write private state file", path: path, errorNumber: errno)
                }
                offset += count
            }
        }
    }

    private static func posixError(operation: String, path: String, errorNumber: Int32) -> HeadlessCommandError {
        let detail = String(cString: Darwin.strerror(errorNumber))
        return HeadlessCommandError("Unable to \(operation) '\(path)': \(detail)", exitCode: 2)
    }
}
