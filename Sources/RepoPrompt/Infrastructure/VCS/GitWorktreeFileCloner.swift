import Darwin
import Foundation

struct GitWorktreeFileClonerError: Error, Equatable, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

/// Descriptor-relative APFS clone primitives shared by tracked-checkout materialization and
/// `.worktreeinclude` copying.
///
/// Every path component below a trusted root is opened relative to an already-open parent
/// directory with `O_NOFOLLOW`, so a symlink swapped into either tree cannot redirect a read
/// or a write outside the intended root. Destination entries are always created exclusively
/// (`fclonefileat`, `O_EXCL`, `symlinkat`), so an existing destination is never overwritten.
enum GitWorktreeFileCloner {
    /// Returns `0` on success or the `errno` reported by the clone attempt.
    typealias CloneSyscall = @Sendable (
        _ sourceDescriptor: Int32,
        _ destinationDirectoryDescriptor: Int32,
        _ destinationName: String,
        _ flags: UInt32
    ) -> Int32

    static let systemClone: CloneSyscall = { source, directory, name, flags in
        fclonefileat(source, directory, name, flags) == 0 ? 0 : errno
    }

    enum Outcome: Equatable {
        case cloned
        case copied
        case symbolicLinkCreated
        case destinationExists
        case sourceMissing
        case sourceTypeMismatch
        case cloneUnsupported(errno: Int32)
        case failed(operation: String, errno: Int32)

        var isMaterialized: Bool {
            switch self {
            case .cloned, .copied, .symbolicLinkCreated: true
            default: false
            }
        }
    }

    enum DestinationMetadata: Equatable {
        /// Keep the source metadata carried by the clone or `COPYFILE_ALL` copy.
        case preserveSource
        /// Match a fresh Git checkout: `0644`/`0755`, no BSD flags, no extended attributes.
        case checkoutNormalized(executable: Bool)
    }

    /// Clones one regular file into `destinationDirectory/name`.
    ///
    /// - Parameter allowCopyFallback: when the volume cannot clone (`ENOTSUP`/`EXDEV`), copy the
    ///   data with `fcopyfile` into an exclusively created destination instead of failing.
    static func cloneRegularFile(
        sourceDirectory: Int32,
        name: String,
        destinationDirectory: Int32,
        metadata: DestinationMetadata,
        allowCopyFallback: Bool,
        clone: CloneSyscall = systemClone,
        sourceSize: ((Int64) -> Void)? = nil
    ) -> Outcome {
        let source = openat(sourceDirectory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else {
            let code = errno
            switch code {
            case ENOENT: return .sourceMissing
            case ELOOP: return .sourceTypeMismatch
            default: return .failed(operation: "open-source", errno: code)
            }
        }
        defer { close(source) }
        var status = stat()
        guard fstat(source, &status) == 0 else {
            return .failed(operation: "stat-source", errno: errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else { return .sourceTypeMismatch }
        sourceSize?(Int64(status.st_size))

        let cloneResult = clone(source, destinationDirectory, name, UInt32(CLONE_NOOWNERCOPY))
        let outcome: Outcome
        switch cloneResult {
        case 0:
            outcome = .cloned
        case EEXIST:
            return .destinationExists
        case ENOTSUP, EXDEV:
            guard allowCopyFallback else { return .cloneUnsupported(errno: cloneResult) }
            let copyOutcome = copyRegularFile(source: source, destinationDirectory: destinationDirectory, name: name)
            guard copyOutcome == .copied else { return copyOutcome }
            outcome = .copied
        default:
            return .failed(operation: "clone", errno: cloneResult)
        }

        if case let .checkoutNormalized(executable) = metadata,
           let failure = normalizeCheckoutMetadata(
               directory: destinationDirectory,
               name: name,
               executable: executable
           )
        {
            return failure
        }
        return outcome
    }

    /// Recreates one symbolic link without following it on either side.
    static func copySymbolicLink(
        sourceDirectory: Int32,
        name: String,
        destinationDirectory: Int32
    ) -> Outcome {
        var status = stat()
        guard fstatat(sourceDirectory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return code == ENOENT ? .sourceMissing : .failed(operation: "stat-source-link", errno: code)
        }
        guard status.st_mode & S_IFMT == S_IFLNK else { return .sourceTypeMismatch }

        let capacity = max(Int(status.st_size), 0) + 1
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        let length = readlinkat(sourceDirectory, name, &buffer, capacity)
        guard length >= 0 else {
            let code = errno
            return code == EINVAL ? .sourceTypeMismatch : .failed(operation: "read-link", errno: code)
        }
        // A longer target than `lstat` reported means the link changed underneath us.
        guard length < capacity else { return .failed(operation: "read-link", errno: EAGAIN) }
        buffer[length] = 0
        guard symlinkat(buffer, destinationDirectory, name) == 0 else {
            let code = errno
            return code == EEXIST ? .destinationExists : .failed(operation: "create-link", errno: code)
        }
        return .symbolicLinkCreated
    }

    private static func copyRegularFile(source: Int32, destinationDirectory: Int32, name: String) -> Outcome {
        let destination = openat(
            destinationDirectory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard destination >= 0 else {
            let code = errno
            return code == EEXIST ? .destinationExists : .failed(operation: "create-destination", errno: code)
        }
        let result = fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ALL))
        let copyErrno = errno
        close(destination)
        guard result == 0 else {
            unlinkat(destinationDirectory, name, 0)
            return .failed(operation: "copy", errno: copyErrno)
        }
        return .copied
    }

    private static func normalizeCheckoutMetadata(
        directory: Int32,
        name: String,
        executable: Bool
    ) -> Outcome? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failed(operation: "open-destination", errno: errno) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            return .failed(operation: "stat-destination", errno: errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            return .failed(operation: "destination-type", errno: EFTYPE)
        }
        if status.st_flags != 0, fchflags(descriptor, 0) != 0 {
            return .failed(operation: "clear-flags", errno: errno)
        }
        if let failure = removeExtendedAttributes(descriptor) {
            return failure
        }
        let mode: mode_t = executable ? 0o755 : 0o644
        if status.st_mode & 0o7777 != mode, fchmod(descriptor, mode) != 0 {
            return .failed(operation: "chmod", errno: errno)
        }
        return nil
    }

    private static func removeExtendedAttributes(_ descriptor: Int32) -> Outcome? {
        let size = flistxattr(descriptor, nil, 0, 0)
        guard size >= 0 else { return .failed(operation: "list-xattr", errno: errno) }
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let length = flistxattr(descriptor, &buffer, size, 0)
        guard length >= 0 else { return .failed(operation: "list-xattr", errno: errno) }
        var start = 0
        for index in 0 ..< length where buffer[index] == 0 {
            defer { start = index + 1 }
            guard index > start else { continue }
            let attributeName = Array(buffer[start ... index])
            if fremovexattr(descriptor, attributeName, 0) != 0, errno != ENOATTR {
                return .failed(operation: "remove-xattr", errno: errno)
            }
        }
        return nil
    }

    /// Walks directory descriptors below one trusted root without following symlinks.
    ///
    /// Consecutive lookups that share a parent prefix reuse the already-open descriptors,
    /// so sorted Git path lists open each directory once while holding at most one
    /// descriptor per directory level.
    final class DirectoryCursor {
        private var descriptors: [Int32]
        private var components: [String] = []
        private let createMissing: Bool

        /// - Parameter noFollowRoot: refuse a root whose final component is a symlink. Callers
        ///   pass canonical roots for tracked-checkout materialization.
        /// - Parameter expectedRootIdentity: when set, the opened root must still be this
        ///   `(device, inode)`, so a root swapped after it was pinned is rejected.
        init(
            rootPath: String,
            createMissing: Bool,
            noFollowRoot: Bool = false,
            expectedRootIdentity: (dev_t, ino_t)? = nil
        ) throws {
            let rootFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (noFollowRoot ? O_NOFOLLOW : 0)
            let descriptor = open(rootPath, rootFlags)
            guard descriptor >= 0 else {
                throw GitWorktreeFileClonerError(operation: "open-root", code: errno)
            }
            if let expectedRootIdentity {
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                      status.st_dev == expectedRootIdentity.0,
                      status.st_ino == expectedRootIdentity.1
                else {
                    close(descriptor)
                    throw GitWorktreeFileClonerError(operation: "verify-root-identity", code: ESTALE)
                }
            }
            descriptors = [descriptor]
            self.createMissing = createMissing
        }

        /// Retain a descriptor-pinned admitted root instead of reopening its pathname.
        init(rootDescriptor: Int32, createMissing: Bool) throws {
            let descriptor = dup(rootDescriptor)
            guard descriptor >= 0 else {
                throw GitWorktreeFileClonerError(operation: "duplicate-root", code: errno)
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                let code = errno
                close(descriptor)
                throw GitWorktreeFileClonerError(operation: "verify-root-descriptor", code: code)
            }
            descriptors = [descriptor]
            self.createMissing = createMissing
        }

        deinit {
            for descriptor in descriptors {
                close(descriptor)
            }
        }

        func directory(for parentComponents: ArraySlice<String>) throws -> Int32 {
            var common = 0
            let limit = min(components.count, parentComponents.count)
            while common < limit,
                  components[common] == parentComponents[parentComponents.startIndex + common]
            {
                common += 1
            }
            while components.count > common {
                close(descriptors.removeLast())
                components.removeLast()
            }
            for component in parentComponents.dropFirst(common) {
                let parent = descriptors[descriptors.count - 1]
                var child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT, createMissing {
                    if mkdirat(parent, component, 0o777) != 0, errno != EEXIST {
                        throw GitWorktreeFileClonerError(operation: "create-directory", code: errno)
                    }
                    child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else {
                    throw GitWorktreeFileClonerError(operation: "open-directory", code: errno)
                }
                descriptors.append(child)
                components.append(component)
            }
            return descriptors[descriptors.count - 1]
        }
    }
}
