import Darwin
import Foundation

struct HeadlessSecureFileMetadata: Equatable {
    enum Kind: Equatable {
        case directory
        case regularFile
    }

    var kind: Kind
    var byteCount: Int64
}

struct HeadlessSecureFileSnapshot {
    var data: Data
    var byteCount: Int64
}

final class HeadlessSecureFileAccess {
    typealias ComponentOpenHook = (_ relativePath: String, _ descriptor: Int32) -> Void

    private let componentOpenHook: ComponentOpenHook?

    init(componentOpenHook: ComponentOpenHook? = nil) {
        self.componentOpenHook = componentOpenHook
    }

    func inspect(root: HeadlessAllowedRoot, relativePath: String) throws -> HeadlessSecureFileMetadata {
        let opened = try openNode(root: root, relativePath: relativePath)
        defer { Darwin.close(opened.descriptor) }
        return try metadata(from: opened.status, displayPath: displayPath(root: root, relativePath: relativePath))
    }

    func readRegularFile(root: HeadlessAllowedRoot, relativePath: String, maximumBytes: Int) throws -> HeadlessSecureFileSnapshot {
        guard maximumBytes >= 0 else {
            throw HeadlessCommandError("Maximum readable byte count must not be negative.", exitCode: 2)
        }
        let opened = try openNode(root: root, relativePath: relativePath)
        defer { Darwin.close(opened.descriptor) }

        let displayPath = displayPath(root: root, relativePath: relativePath)
        let metadata = try metadata(from: opened.status, displayPath: displayPath)
        guard metadata.kind == .regularFile else {
            throw HeadlessCommandError("Path is not a regular file: \(displayPath)", exitCode: 2)
        }
        guard metadata.byteCount <= Int64(maximumBytes) else {
            throw HeadlessCommandError("File is too large to read in headless v1 (\(metadata.byteCount) bytes > \(maximumBytes)): \(displayPath)", exitCode: 2)
        }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(metadata.byteCount))))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(opened.descriptor, baseAddress, rawBuffer.count)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw posixError(operation: "read", path: displayPath, errorNumber: errno)
            }
            guard data.count <= maximumBytes - count else {
                throw HeadlessCommandError("File grew beyond the headless read limit (\(maximumBytes) bytes): \(displayPath)", exitCode: 2)
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
        return HeadlessSecureFileSnapshot(data: data, byteCount: metadata.byteCount)
    }

    private func openNode(root: HeadlessAllowedRoot, relativePath: String) throws -> (descriptor: Int32, status: stat) {
        let components = try validatedComponents(relativePath)
        let rootDescriptor = Darwin.open(root.resolvedPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw posixError(operation: "open allowed root", path: root.resolvedPath, errorNumber: errno)
        }

        var currentDescriptor = rootDescriptor
        var traversed: [String] = []
        if components.isEmpty {
            var status = stat()
            guard Darwin.fstat(currentDescriptor, &status) == 0 else {
                let savedErrno = errno
                Darwin.close(currentDescriptor)
                throw posixError(operation: "inspect allowed root", path: root.resolvedPath, errorNumber: savedErrno)
            }
            componentOpenHook?("", currentDescriptor)
            return (currentDescriptor, status)
        }

        for (index, component) in components.enumerated() {
            let isLeaf = index == components.count - 1
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLeaf ? O_NONBLOCK : O_DIRECTORY)
            let nextDescriptor = component.withCString { pointer in
                Darwin.openat(currentDescriptor, pointer, flags)
            }
            guard nextDescriptor >= 0 else {
                let savedErrno = errno
                Darwin.close(currentDescriptor)
                traversed.append(component)
                throw posixError(operation: "open", path: displayPath(root: root, relativePath: traversed.joined(separator: "/")), errorNumber: savedErrno)
            }

            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
            traversed.append(component)

            var status = stat()
            guard Darwin.fstat(currentDescriptor, &status) == 0 else {
                let savedErrno = errno
                Darwin.close(currentDescriptor)
                throw posixError(operation: "inspect", path: displayPath(root: root, relativePath: traversed.joined(separator: "/")), errorNumber: savedErrno)
            }
            if !isLeaf, (status.st_mode & S_IFMT) != S_IFDIR {
                Darwin.close(currentDescriptor)
                throw HeadlessCommandError("Path component is not a directory: \(displayPath(root: root, relativePath: traversed.joined(separator: "/")))", exitCode: 2)
            }
            componentOpenHook?(traversed.joined(separator: "/"), currentDescriptor)
            if isLeaf {
                return (currentDescriptor, status)
            }
        }

        Darwin.close(currentDescriptor)
        throw HeadlessCommandError("Unable to open path: \(displayPath(root: root, relativePath: relativePath))", exitCode: 2)
    }

    private func validatedComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.hasPrefix("/") else {
            throw HeadlessCommandError("Resolved path must remain relative to its allowed root.", exitCode: 2)
        }
        guard !relativePath.utf8.contains(0) else {
            throw HeadlessCommandError("Path must not contain NUL bytes.", exitCode: 2)
        }
        guard !relativePath.isEmpty else { return [] }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw HeadlessCommandError("Path contains an invalid component: \(relativePath)", exitCode: 2)
        }
        return components
    }

    private func metadata(from status: stat, displayPath: String) throws -> HeadlessSecureFileMetadata {
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            return HeadlessSecureFileMetadata(kind: .directory, byteCount: Int64(status.st_size))
        case S_IFREG:
            return HeadlessSecureFileMetadata(kind: .regularFile, byteCount: Int64(status.st_size))
        default:
            throw HeadlessCommandError("Path is not a regular file or directory: \(displayPath)", exitCode: 2)
        }
    }

    private func displayPath(root: HeadlessAllowedRoot, relativePath: String) -> String {
        relativePath.isEmpty ? root.name : "\(root.name)/\(relativePath)"
    }

    private func posixError(operation: String, path: String, errorNumber: Int32) -> HeadlessCommandError {
        let detail = String(cString: Darwin.strerror(errorNumber))
        return HeadlessCommandError("Unable to \(operation) '\(path)': \(detail)", exitCode: 2)
    }
}
