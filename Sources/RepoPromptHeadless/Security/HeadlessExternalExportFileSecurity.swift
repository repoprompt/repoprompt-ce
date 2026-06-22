import Darwin
import Foundation

/// Descriptor-relative writes for explicitly authorized exports outside private headless state.
///
/// Unlike `HeadlessStateFileSecurity`, this writer does not impose state ownership or
/// directory-mode policy on existing external paths. It pins the destination parent
/// descriptor, rejects a symlink/non-regular leaf, and performs a same-directory
/// temporary-file rename so parent replacement cannot redirect the write.
enum HeadlessExternalExportFileSecurity {
    typealias ParentDirectoryOpenedHook = (Int32) throws -> Void

    private static let createdDirectoryMode: mode_t = S_IRWXU
    private static let fileMode: mode_t = S_IRUSR | S_IWUSR

    static func writeFile(
        _ data: Data,
        to url: URL,
        parentDirectoryOpenedHook: ParentDirectoryOpenedHook? = nil
    ) throws {
        let target = url.standardizedFileURL
        guard target.path.hasPrefix("/"), !target.lastPathComponent.isEmpty else {
            throw HeadlessCommandError("External export path must be an absolute non-root file path: \(url.path)", exitCode: 2)
        }

        let parentDescriptor = try openDirectoryCreatingMissing(at: target.deletingLastPathComponent())
        defer { Darwin.close(parentDescriptor) }
        try parentDirectoryOpenedHook?(parentDescriptor)
        try validateExistingRegularFileIfPresent(
            named: target.lastPathComponent,
            relativeTo: parentDescriptor,
            path: target.path
        )

        let temporaryName = ".\(target.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString { pointer in
            Darwin.openat(
                parentDescriptor,
                pointer,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                fileMode
            )
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "create external export file", path: target.path, errorNumber: errno)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                temporaryName.withCString { pointer in _ = Darwin.unlinkat(parentDescriptor, pointer, 0) }
            }
        }

        try validateOpenedFile(descriptor, path: target.path)
        try writeAll(data, to: descriptor, path: target.path)
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(operation: "sync external export file", path: target.path, errorNumber: errno)
        }
        let renameResult = temporaryName.withCString { temporaryPointer in
            target.lastPathComponent.withCString { targetPointer in
                Darwin.renameat(parentDescriptor, temporaryPointer, parentDescriptor, targetPointer)
            }
        }
        guard renameResult == 0 else {
            throw posixError(operation: "replace external export file", path: target.path, errorNumber: errno)
        }
        shouldRemoveTemporaryFile = false
        try validateExistingRegularFileIfPresent(
            named: target.lastPathComponent,
            relativeTo: parentDescriptor,
            path: target.path,
            requirePresent: true
        )
    }

    private static func openDirectoryCreatingMissing(at url: URL) throws -> Int32 {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !pathExists(ancestor.path) {
            let component = ancestor.lastPathComponent
            guard !component.isEmpty else {
                throw HeadlessCommandError("Unable to find an existing ancestor for external export path: \(url.path)", exitCode: 2)
            }
            missingComponents.insert(component, at: 0)
            ancestor.deleteLastPathComponent()
        }

        var descriptor = Darwin.open(ancestor.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(operation: "open external export directory", path: ancestor.path, errorNumber: errno)
        }
        do {
            try validateOpenedDirectory(descriptor, path: ancestor.path)
            for component in missingComponents {
                try validateComponent(component, path: url.path)
                let mkdirResult = component.withCString { pointer in
                    Darwin.mkdirat(descriptor, pointer, createdDirectoryMode)
                }
                if mkdirResult != 0, errno != EEXIST {
                    throw posixError(operation: "create external export directory", path: url.path, errorNumber: errno)
                }
                let nextDescriptor = component.withCString { pointer in
                    Darwin.openat(descriptor, pointer, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard nextDescriptor >= 0 else {
                    throw posixError(operation: "open external export directory", path: url.path, errorNumber: errno)
                }
                try validateOpenedDirectory(nextDescriptor, path: url.path)
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateExistingRegularFileIfPresent(
        named name: String,
        relativeTo parentDescriptor: Int32,
        path: String,
        requirePresent: Bool = false
    ) throws {
        try validateComponent(name, path: path)
        let descriptor = name.withCString { pointer in
            Darwin.openat(parentDescriptor, pointer, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0, !requirePresent, errno == ENOENT {
            return
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open external export target", path: path, errorNumber: errno)
        }
        defer { Darwin.close(descriptor) }
        try validateOpenedFile(descriptor, path: path)
    }

    private static func validateOpenedDirectory(_ descriptor: Int32, path: String) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError(operation: "inspect external export directory", path: path, errorNumber: errno)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw HeadlessCommandError("External export parent is not a directory: \(path)", exitCode: 2)
        }
    }

    private static func validateOpenedFile(_ descriptor: Int32, path: String) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw posixError(operation: "inspect external export file", path: path, errorNumber: errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw HeadlessCommandError("External export target has an unsafe file type: \(path)", exitCode: 2)
        }
    }

    private static func validateComponent(_ component: String, path: String) throws {
        guard !component.isEmpty, component != ".", component != "..", !component.utf8.contains(0) else {
            throw HeadlessCommandError("External export path contains an invalid component: \(path)", exitCode: 2)
        }
    }

    private static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(operation: "write external export file", path: path, errorNumber: errno)
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
