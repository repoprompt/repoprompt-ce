import Darwin
import Foundation

package enum DomainMutationPhysicalCapabilityError: Error, Equatable, LocalizedError {
    case scopeUnavailable
    case unsupportedOperation(String)
    case pathOutsideAuthorizedRoots(String)
    case invalidComponent(String)
    case symlinkNotAllowed(String)
    case missingParent(String)
    case sourceMissing(String)
    case destinationExists(String)
    case notRegularFile(String)
    case expectedContentChanged(String)
    case crossVolume(String)
    case ioFailure(operation: String, code: Int32)

    package var errorDescription: String? {
        switch self {
        case .scopeUnavailable:
            "Protected physical mutation denied because no descriptor-backed capability is available."
        case let .unsupportedOperation(operation):
            "Protected physical mutation is unsupported for operation: \(operation)."
        case let .pathOutsideAuthorizedRoots(path):
            "Protected physical mutation path is outside the admitted descriptor scope: \(path)."
        case let .invalidComponent(component):
            "Protected physical mutation rejected an invalid path component: \(component)."
        case let .symlinkNotAllowed(path):
            "Protected physical mutation rejected a symbolic link in the physical path: \(path)."
        case let .missingParent(path):
            "Protected physical mutation parent directory is unavailable: \(path)."
        case let .sourceMissing(path):
            "Protected physical mutation source is missing: \(path)."
        case let .destinationExists(path):
            "Protected no-replace mutation destination already exists: \(path)."
        case let .notRegularFile(path):
            "Protected physical mutation supports regular files only: \(path)."
        case let .expectedContentChanged(path):
            "Protected edit rejected because the admitted file content changed: \(path)."
        case let .crossVolume(path):
            "Protected no-replace move cannot cross volumes: \(path)."
        case let .ioFailure(operation, code):
            "Protected physical mutation failed during \(operation) with errno \(code)."
        }
    }
}

/// An admitted physical namespace capability. It retains directory descriptors and never
/// re-resolves the protected target through an absolute pathname during mutation.
package final class DomainMutationPhysicalCapability: @unchecked Sendable {
    private let lease: DomainMutationPhysicalLease

    package static func open(
        snapshot: DomainMutationPathFenceSnapshot
    ) throws -> DomainMutationPhysicalCapability {
        try DomainMutationPhysicalCapability(lease: DomainMutationPhysicalLease(snapshot: snapshot))
    }

    private init(lease: DomainMutationPhysicalLease) {
        self.lease = lease
    }

    package func validateNoReplaceMove(
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        let source = try lease.plan(for: sourcePath)
        let destination = try lease.plan(for: destinationPath)
        let sourceParent = try source.existingParent()
        let existingDestinationParent = try destination.existingParent()
        guard let sourceParent else {
            throw DomainMutationPhysicalCapabilityError.missingParent(source.absolutePath)
        }
        let destinationParent = existingDestinationParent ?? destination.base
        try validateRegularEntry(parent: sourceParent, name: source.leaf, path: source.absolutePath)
        if let existingDestinationParent,
           try lookup(parent: existingDestinationParent, name: destination.leaf, path: destination.absolutePath) != nil
        {
            throw DomainMutationPhysicalCapabilityError.destinationExists(destination.absolutePath)
        }
        guard try device(of: sourceParent) == device(of: destinationParent) else {
            throw DomainMutationPhysicalCapabilityError.crossVolume(destination.absolutePath)
        }
    }

    package func moveFile(
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        let source = try lease.plan(for: sourcePath)
        let destination = try lease.plan(for: destinationPath)
        guard let sourceParent = try source.existingParent() else {
            throw DomainMutationPhysicalCapabilityError.missingParent(source.absolutePath)
        }
        let destinationParent = try destination.materializedParent()
        try validateRegularEntry(parent: sourceParent, name: source.leaf, path: source.absolutePath)
        guard try device(of: sourceParent) == device(of: destinationParent) else {
            throw DomainMutationPhysicalCapabilityError.crossVolume(destination.absolutePath)
        }
        if try lookup(parent: destinationParent, name: destination.leaf, path: destination.absolutePath) != nil {
            throw DomainMutationPhysicalCapabilityError.destinationExists(destination.absolutePath)
        }

        let result = renameatx_np(
            sourceParent.fd,
            source.leaf,
            destinationParent.fd,
            destination.leaf,
            UInt32(RENAME_EXCL)
        )
        guard result == 0 else {
            let code = errno
            switch code {
            case EEXIST:
                throw DomainMutationPhysicalCapabilityError.destinationExists(destination.absolutePath)
            case ENOENT:
                throw DomainMutationPhysicalCapabilityError.sourceMissing(source.absolutePath)
            case EXDEV:
                throw DomainMutationPhysicalCapabilityError.crossVolume(destination.absolutePath)
            default:
                throw DomainMutationPhysicalCapabilityError.ioFailure(
                    operation: "relative-no-replace-move",
                    code: code
                )
            }
        }
        try synchronize(sourceParent.fd, operation: "move-source-parent-sync")
        if sourceParent.fd != destinationParent.fd {
            try synchronize(destinationParent.fd, operation: "move-destination-parent-sync")
        }
    }

    package func validateWriteTarget(
        at path: String,
        overwrite: Bool,
        expectedContentDigest: String?,
        requireExisting: Bool
    ) throws {
        let plan = try lease.plan(for: path)
        guard let parent = try plan.existingParent() else {
            if requireExisting {
                throw DomainMutationPhysicalCapabilityError.missingParent(plan.absolutePath)
            }
            return
        }
        guard let existing = try lookup(parent: parent, name: plan.leaf, path: plan.absolutePath) else {
            if requireExisting {
                throw DomainMutationPhysicalCapabilityError.sourceMissing(plan.absolutePath)
            }
            return
        }
        guard existing.isRegular || overwrite else {
            throw DomainMutationPhysicalCapabilityError.notRegularFile(plan.absolutePath)
        }
        guard overwrite else {
            throw DomainMutationPhysicalCapabilityError.destinationExists(plan.absolutePath)
        }
        let descriptor = try openRegularFile(parent: parent, name: plan.leaf, path: plan.absolutePath)
        if let expectedContentDigest {
            let currentDigest = try digest(of: descriptor.fd)
            guard currentDigest == expectedContentDigest else {
                throw DomainMutationPhysicalCapabilityError.expectedContentChanged(plan.absolutePath)
            }
        }
    }

    package func writeFile(
        at path: String,
        data: Data,
        overwrite: Bool,
        expectedContentDigest: String?,
        requireExisting: Bool
    ) throws {
        let plan = try lease.plan(for: path)
        let parent: DomainMutationPhysicalDescriptor
        if let existingParent = try plan.existingParent() {
            parent = existingParent
        } else {
            guard !requireExisting else {
                throw DomainMutationPhysicalCapabilityError.missingParent(plan.absolutePath)
            }
            parent = try plan.materializedParent()
        }

        let existing = try lookup(parent: parent, name: plan.leaf, path: plan.absolutePath)
        if let existing {
            guard overwrite else {
                throw DomainMutationPhysicalCapabilityError.destinationExists(plan.absolutePath)
            }
            guard existing.isRegular else {
                throw DomainMutationPhysicalCapabilityError.notRegularFile(plan.absolutePath)
            }
            try replaceExistingFile(
                parent: parent,
                name: plan.leaf,
                path: plan.absolutePath,
                data: data,
                expectedContentDigest: expectedContentDigest
            )
        } else {
            guard !requireExisting else {
                throw DomainMutationPhysicalCapabilityError.sourceMissing(plan.absolutePath)
            }
            try createNewFile(parent: parent, name: plan.leaf, path: plan.absolutePath, data: data)
        }
    }

    private func createNewFile(
        parent: DomainMutationPhysicalDescriptor,
        name: String,
        path: String,
        data: Data
    ) throws {
        let descriptor = openat(
            parent.fd,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o644)
        )
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case EEXIST:
                throw DomainMutationPhysicalCapabilityError.destinationExists(path)
            case ELOOP:
                throw DomainMutationPhysicalCapabilityError.symlinkNotAllowed(path)
            default:
                throw DomainMutationPhysicalCapabilityError.ioFailure(
                    operation: "relative-create-open",
                    code: code
                )
            }
        }
        let created = DomainMutationPhysicalDescriptor(descriptor)
        try write(data, to: created.fd, operation: "relative-create-write")
        try synchronize(created.fd, operation: "relative-create-file-sync")
        try synchronize(parent.fd, operation: "relative-create-parent-sync")
    }

    private func replaceExistingFile(
        parent: DomainMutationPhysicalDescriptor,
        name: String,
        path: String,
        data: Data,
        expectedContentDigest: String?
    ) throws {
        let target = try openRegularFile(parent: parent, name: name, path: path)
        // Atomic replacement changes the inode; retain the supported POSIX mode contract.
        let targetMode = try permissionMode(of: target.fd)
        if let expectedContentDigest {
            let currentDigest = try digest(of: target.fd)
            guard currentDigest == expectedContentDigest else {
                throw DomainMutationPhysicalCapabilityError.expectedContentChanged(path)
            }
        }

        var temporaryName: String?
        var temporaryDescriptor: DomainMutationPhysicalDescriptor?
        for _ in 0 ..< 8 {
            let candidate = ".rpce-mutation-\(UUID().uuidString.lowercased())"
            let descriptor = openat(
                parent.fd,
                candidate,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            if descriptor >= 0 {
                temporaryName = candidate
                temporaryDescriptor = DomainMutationPhysicalDescriptor(descriptor)
                break
            }
            guard errno == EEXIST else {
                throw DomainMutationPhysicalCapabilityError.ioFailure(
                    operation: "relative-replace-temp-open",
                    code: errno
                )
            }
        }
        guard let createdName = temporaryName, let temporaryDescriptor else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-replace-temp-name",
                code: EBUSY
            )
        }

        guard fchmod(temporaryDescriptor.fd, targetMode) == 0 else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-replace-temp-mode",
                code: errno
            )
        }
        try write(data, to: temporaryDescriptor.fd, operation: "relative-replace-write")
        try synchronize(temporaryDescriptor.fd, operation: "relative-replace-file-sync")
        guard renameat(parent.fd, createdName, parent.fd, name) == 0 else {
            // Do not attempt pathname cleanup here. The temporary entry is not an
            // authority for deletion after a failure and may have been replaced.
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-atomic-replace",
                code: errno
            )
        }
        // A post-rename parent fsync failure is intentionally reported as an
        // indeterminate/partial outcome to the protected caller.
        try synchronize(parent.fd, operation: "relative-replace-parent-sync")
    }

    private func validateRegularEntry(
        parent: DomainMutationPhysicalDescriptor,
        name: String,
        path: String
    ) throws {
        guard let value = try lookup(parent: parent, name: name, path: path) else {
            throw DomainMutationPhysicalCapabilityError.sourceMissing(path)
        }
        guard value.isRegular else {
            throw DomainMutationPhysicalCapabilityError.notRegularFile(path)
        }
    }

    private func openRegularFile(
        parent: DomainMutationPhysicalDescriptor,
        name: String,
        path: String
    ) throws -> DomainMutationPhysicalDescriptor {
        // Avoid blocking if a concurrent replacement turns the entry into a FIFO.
        let descriptor = openat(parent.fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT:
                throw DomainMutationPhysicalCapabilityError.sourceMissing(path)
            case ELOOP:
                throw DomainMutationPhysicalCapabilityError.symlinkNotAllowed(path)
            default:
                throw DomainMutationPhysicalCapabilityError.ioFailure(
                    operation: "relative-file-open",
                    code: code
                )
            }
        }
        let value = DomainMutationPhysicalDescriptor(descriptor)
        guard try isRegular(value.fd) else {
            throw DomainMutationPhysicalCapabilityError.notRegularFile(path)
        }
        return value
    }

    private func lookup(
        parent: DomainMutationPhysicalDescriptor,
        name: String,
        path: String
    ) throws -> DomainMutationPhysicalFileIdentity? {
        var status = stat()
        guard fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP {
                throw DomainMutationPhysicalCapabilityError.symlinkNotAllowed(path)
            }
            throw DomainMutationPhysicalCapabilityError.ioFailure(operation: "relative-entry-stat", code: code)
        }
        return DomainMutationPhysicalFileIdentity(status)
    }

    private func isRegular(_ descriptor: Int32) throws -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-file-descriptor-stat",
                code: errno
            )
        }
        return status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private func permissionMode(of descriptor: Int32) throws -> mode_t {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-file-permission-stat",
                code: errno
            )
        }
        return status.st_mode & mode_t(0o7777)
    }

    private func digest(of descriptor: Int32) throws -> String {
        let data = try read(descriptor: descriptor)
        return DomainContentDigest.sha256(data)
    }

    private func read(descriptor: Int32) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-content-stat",
                code: errno
            )
        }
        guard status.st_size >= 0, status.st_size <= off_t(Int.max) else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-content-size",
                code: EFBIG
            )
        }
        var data = Data(count: Int(status.st_size))
        var offset: off_t = 0
        while offset < status.st_size {
            let remaining = Int(status.st_size - offset)
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return pread(descriptor, base.advanced(by: Int(offset)), remaining, offset)
            }
            guard count > 0 else {
                let code = count == 0 ? EIO : errno
                throw DomainMutationPhysicalCapabilityError.ioFailure(
                    operation: "relative-content-read",
                    code: code
                )
            }
            offset += off_t(count)
        }
        return data
    }

    private func write(
        _ data: Data,
        to descriptor: Int32,
        operation: String
    ) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            guard count > 0 else {
                let code = count == 0 ? EIO : errno
                throw DomainMutationPhysicalCapabilityError.ioFailure(operation: operation, code: code)
            }
            offset += count
        }
    }

    private func synchronize(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw DomainMutationPhysicalCapabilityError.ioFailure(operation: operation, code: errno)
            }
        }
    }

    private func device(of descriptor: DomainMutationPhysicalDescriptor) throws -> dev_t {
        var status = stat()
        guard fstat(descriptor.fd, &status) == 0 else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "relative-directory-stat",
                code: errno
            )
        }
        return status.st_dev
    }
}

private final class DomainMutationPhysicalLease: @unchecked Sendable {
    private let plans: [String: DomainMutationPhysicalTargetPlan]

    init(snapshot: DomainMutationPathFenceSnapshot) throws {
        var roots: [DomainMutationPathIdentity: DomainMutationPhysicalDescriptor] = [:]
        for root in snapshot.authorizedRoots {
            let descriptor = try Self.openRoot(root)
            roots[root] = descriptor
        }

        var builtPlans: [String: DomainMutationPhysicalTargetPlan] = [:]
        for entry in snapshot.entries {
            guard let rootDescriptor = roots[entry.authorizedRoot] else {
                throw DomainMutationPhysicalCapabilityError.scopeUnavailable
            }
            let plan = try Self.makePlan(entry: entry, root: entry.authorizedRoot, descriptor: rootDescriptor)
            builtPlans[plan.absolutePath] = plan
        }
        guard !builtPlans.isEmpty else {
            throw DomainMutationPhysicalCapabilityError.scopeUnavailable
        }
        plans = builtPlans
    }

    func plan(for path: String) throws -> DomainMutationPhysicalTargetPlan {
        guard !path.contains("\0") else {
            throw DomainMutationPhysicalCapabilityError.invalidComponent(path)
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let plan = plans[standardized] else {
            throw DomainMutationPhysicalCapabilityError.pathOutsideAuthorizedRoots(path)
        }
        return plan
    }

    private static func openRoot(
        _ identity: DomainMutationPathIdentity
    ) throws -> DomainMutationPhysicalDescriptor {
        guard !identity.originalPath.contains("\0") else {
            throw DomainMutationPhysicalCapabilityError.invalidComponent(identity.originalPath)
        }
        let descriptor = identity.originalPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw DomainMutationPhysicalCapabilityError.symlinkNotAllowed(identity.originalPath)
            }
            throw DomainMutationPhysicalCapabilityError.ioFailure(operation: "authorized-root-open", code: code)
        }
        let value = DomainMutationPhysicalDescriptor(descriptor)
        var status = stat()
        guard fstat(value.fd, &status) == 0 else {
            throw DomainMutationPhysicalCapabilityError.ioFailure(
                operation: "authorized-root-stat",
                code: errno
            )
        }
        guard status.st_dev == dev_t(identity.device),
              status.st_ino == ino_t(identity.inode),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw DomainMutationPhysicalCapabilityError.scopeUnavailable
        }
        return value
    }

    private static func makePlan(
        entry: DomainMutationPathFenceEntry,
        root: DomainMutationPathIdentity,
        descriptor rootDescriptor: DomainMutationPhysicalDescriptor
    ) throws -> DomainMutationPhysicalTargetPlan {
        guard !root.originalPath.contains("\0") else {
            throw DomainMutationPhysicalCapabilityError.invalidComponent(root.originalPath)
        }
        guard !entry.requestedPath.contains("\0") else {
            throw DomainMutationPhysicalCapabilityError.invalidComponent(entry.requestedPath)
        }
        let absolutePath = URL(fileURLWithPath: entry.requestedPath).standardizedFileURL.path
        let rootPrefix = root.originalPath == "/" ? "/" : root.originalPath + "/"
        guard absolutePath.hasPrefix(rootPrefix) else {
            throw DomainMutationPhysicalCapabilityError.pathOutsideAuthorizedRoots(entry.requestedPath)
        }
        let relative = String(absolutePath.dropFirst(rootPrefix.count))
        let components = relative.split(separator: "/").map(String.init)
        guard let leaf = components.last else {
            throw DomainMutationPhysicalCapabilityError.invalidComponent(absolutePath)
        }
        for component in components where component.isEmpty || component == "." || component == ".." {
            throw DomainMutationPhysicalCapabilityError.invalidComponent(component)
        }

        var current = rootDescriptor
        var missingComponents: [String] = []
        var existingAncestorComponents: [String] = []
        var hasMissingComponent = false
        for component in components.dropLast() {
            if hasMissingComponent {
                missingComponents.append(component)
                continue
            }
            let child = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child >= 0 {
                current = DomainMutationPhysicalDescriptor(child)
                existingAncestorComponents.append(component)
                continue
            }
            let code = errno
            if code == ENOENT {
                hasMissingComponent = true
                missingComponents.append(component)
                continue
            }
            if code == ELOOP {
                throw DomainMutationPhysicalCapabilityError.symlinkNotAllowed(absolutePath)
            }
            throw DomainMutationPhysicalCapabilityError.ioFailure(operation: "authorized-parent-open", code: code)
        }

        let existingAncestorPath: String = if existingAncestorComponents.isEmpty {
            root.originalPath
        } else {
            URL(fileURLWithPath: root.originalPath)
                .appendingPathComponent(existingAncestorComponents.joined(separator: "/"))
                .standardizedFileURL.path
        }

        if entry.existingAnchor.originalPath != entry.requestedPath {
            guard entry.existingAnchor.originalPath == existingAncestorPath else {
                throw DomainMutationPhysicalCapabilityError.scopeUnavailable
            }
            var status = stat()
            guard fstat(current.fd, &status) == 0 else {
                throw DomainMutationPhysicalCapabilityError.ioFailure(
                    operation: "authorized-anchor-stat",
                    code: errno
                )
            }
            guard status.st_dev == dev_t(entry.existingAnchor.device),
                  status.st_ino == ino_t(entry.existingAnchor.inode)
            else {
                throw DomainMutationPhysicalCapabilityError.scopeUnavailable
            }
        }

        return DomainMutationPhysicalTargetPlan(
            absolutePath: absolutePath,
            leaf: leaf,
            base: current,
            missingComponents: missingComponents
        )
    }
}

private final class DomainMutationPhysicalTargetPlan: @unchecked Sendable {
    let absolutePath: String
    let leaf: String
    let base: DomainMutationPhysicalDescriptor
    let missingComponents: [String]

    init(
        absolutePath: String,
        leaf: String,
        base: DomainMutationPhysicalDescriptor,
        missingComponents: [String]
    ) {
        self.absolutePath = absolutePath
        self.leaf = leaf
        self.base = base
        self.missingComponents = missingComponents
    }

    func existingParent() throws -> DomainMutationPhysicalDescriptor? {
        missingComponents.isEmpty ? base : nil
    }

    func materializedParent() throws -> DomainMutationPhysicalDescriptor {
        var current = base
        for component in missingComponents {
            if mkdirat(current.fd, component, mode_t(0o755)) != 0 {
                let code = errno
                guard code == EEXIST else {
                    throw DomainMutationPhysicalCapabilityError.ioFailure(
                        operation: "relative-parent-materialize",
                        code: code
                    )
                }
            }
            let descriptor = openat(
                current.fd,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                let code = errno
                if code == ELOOP {
                    throw DomainMutationPhysicalCapabilityError.symlinkNotAllowed(absolutePath)
                }
                throw DomainMutationPhysicalCapabilityError.ioFailure(
                    operation: "relative-parent-open",
                    code: code
                )
            }
            current = DomainMutationPhysicalDescriptor(descriptor)
        }
        return current
    }
}

private final class DomainMutationPhysicalDescriptor: @unchecked Sendable {
    let fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }
}

private struct DomainMutationPhysicalFileIdentity {
    let mode: mode_t

    init(_ status: stat) {
        mode = status.st_mode & mode_t(S_IFMT)
    }

    var isRegular: Bool {
        mode == mode_t(S_IFREG)
    }
}
