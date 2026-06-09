import Darwin
import Foundation
import RepoPromptCore
import RepoPromptPOSIXSupport

package final class MacOSWorkspaceExternalFileReader: WorkspaceExternalFileReading, @unchecked Sendable {
    package typealias ValidatedDescriptorHook = @Sendable (_ canonicalPath: String, _ descriptor: Int32) -> Void

    private enum ExpectedKind: Equatable {
        case directory
        case regularFile
    }

    private struct OpenedNode {
        let descriptor: Int32
        let canonicalPath: String
    }

    private let validatedDescriptorHook: ValidatedDescriptorHook?

    package init(validatedDescriptorHook: ValidatedDescriptorHook? = nil) {
        self.validatedDescriptorHook = validatedDescriptorHook
    }

    package func resolveRegularFile(
        atAbsolutePath path: String,
        allowedDirectories: [AlwaysReadableDirectory]
    ) throws -> String? {
        do {
            guard let opened = try openValidatedNode(
                atAbsolutePath: path,
                allowedDirectories: allowedDirectories,
                expectedKind: .regularFile
            ) else {
                return nil
            }
            Darwin.close(opened.descriptor)
            return opened.canonicalPath
        } catch ReaderError.unsafeType {
            return nil
        }
    }

    package func resolveDirectory(
        atAbsolutePath path: String,
        allowedDirectories: [AlwaysReadableDirectory]
    ) throws -> String? {
        do {
            guard let opened = try openValidatedNode(
                atAbsolutePath: path,
                allowedDirectories: allowedDirectories,
                expectedKind: .directory
            ) else {
                return nil
            }
            Darwin.close(opened.descriptor)
            return opened.canonicalPath
        } catch ReaderError.unsafeType {
            return nil
        }
    }

    package func readRegularFile(
        atAbsolutePath path: String,
        allowedDirectories: [AlwaysReadableDirectory]
    ) throws -> Data {
        guard let opened = try openValidatedNode(
            atAbsolutePath: path,
            allowedDirectories: allowedDirectories,
            expectedKind: .regularFile
        ) else {
            throw ReaderError.notAllowed(path)
        }
        defer { Darwin.close(opened.descriptor) }
        return try readAll(from: opened.descriptor, path: opened.canonicalPath)
    }

    private func openValidatedNode(
        atAbsolutePath path: String,
        allowedDirectories: [AlwaysReadableDirectory],
        expectedKind: ExpectedKind
    ) throws -> OpenedNode? {
        guard path.hasPrefix("/"), let canonicalCandidate = canonicalExistingPath(path) else {
            return nil
        }
        let allowedRoots = allowedDirectories.compactMap { directory -> (canonical: String, presented: String)? in
            guard let canonical = canonicalExistingPath(directory.standardizedPath) else { return nil }
            return (canonical, directory.standardizedPath)
        }
        guard let allowedRoot = allowedRoots.first(where: { contains(canonicalCandidate, in: $0.canonical) }) else {
            return nil
        }

        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (expectedKind == .directory ? O_DIRECTORY : O_NONBLOCK)
        let descriptor = Darwin.open(canonicalCandidate, flags)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return nil }
            throw posixError(operation: "open", path: canonicalCandidate, errorNumber: errno)
        }

        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw posixError(operation: "inspect", path: canonicalCandidate, errorNumber: errno)
            }
            let actualKind = status.st_mode & S_IFMT
            switch expectedKind {
            case .directory:
                guard actualKind == S_IFDIR else { throw ReaderError.unsafeType(canonicalCandidate) }
            case .regularFile:
                guard actualKind == S_IFREG else { throw ReaderError.unsafeType(canonicalCandidate) }
            }

            let descriptorPath = try pathForDescriptor(descriptor, fallbackPath: canonicalCandidate)
            guard contains(descriptorPath, in: allowedRoot.canonical) else {
                throw ReaderError.escapedRoot(descriptorPath)
            }
            let suffix = String(descriptorPath.dropFirst(allowedRoot.canonical.count))
            let presentedPath = AgentSupportDirectoryCatalog.normalizedPath(for: allowedRoot.presented + suffix)
            validatedDescriptorHook?(presentedPath, descriptor)
            return OpenedNode(descriptor: descriptor, canonicalPath: presentedPath)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func pathForDescriptor(_ descriptor: Int32, fallbackPath: String) throws -> String {
        do {
            let path = try POSIXDescriptorSupport.path(for: descriptor)
            return AgentSupportDirectoryCatalog.normalizedPath(for: path)
        } catch let error as POSIXDescriptorPathError {
            throw posixError(operation: "resolve opened descriptor", path: fallbackPath, errorNumber: error.errnoValue)
        }
    }

    private func canonicalExistingPath(_ path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = Darwin.realpath(pointer, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return AgentSupportDirectoryCatalog.normalizedPath(for: String(cString: resolved))
        }
    }

    private func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func readAll(from descriptor: Int32, path: String) throws -> Data {
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
                throw posixError(operation: "read", path: path, errorNumber: errno)
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
    }

    private func posixError(operation: String, path: String, errorNumber: Int32) -> ReaderError {
        ReaderError.posix(operation: operation, path: path, detail: String(cString: Darwin.strerror(errorNumber)))
    }
}

private enum ReaderError: LocalizedError {
    case escapedRoot(String)
    case notAllowed(String)
    case posix(operation: String, path: String, detail: String)
    case unsafeType(String)

    var errorDescription: String? {
        switch self {
        case let .escapedRoot(path):
            "Opened external support path escaped its allowed root: \(path)"
        case let .notAllowed(path):
            "External support file is not inside an allowed root: \(path)"
        case let .posix(operation, path, detail):
            "Unable to \(operation) external support path '\(path)': \(detail)"
        case let .unsafeType(path):
            "External support path is not the expected regular file or directory: \(path)"
        }
    }
}
