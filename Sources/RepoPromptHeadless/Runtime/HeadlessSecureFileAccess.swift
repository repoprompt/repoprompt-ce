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

struct HeadlessSecureEnumerationEntry {
    var relativePath: String
    var metadata: HeadlessSecureFileMetadata
}

struct HeadlessSecureEnumerationResult {
    var baseMetadata: HeadlessSecureFileMetadata
    var entries: [HeadlessSecureEnumerationEntry]
    var examinedEntryCount: Int
    var skippedEntryCount: Int
    var wasTruncated: Bool
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

    /// Enumerates a root-contained directory tree from one descriptor anchor.
    ///
    /// Every candidate is inspected with `fstatat(..., AT_SYMLINK_NOFOLLOW)`,
    /// reopened with `openat(..., O_NOFOLLOW)`, and checked for inode replacement
    /// before it is returned or traversed. Examined directory entries count
    /// against the budget even when they are skipped.
    func enumerate(
        root: HeadlessAllowedRoot,
        relativePath: String,
        maxEntries: Int,
        maxExaminedEntries: Int? = nil,
        maxEntriesPerDirectory: Int = 1000,
        maxDepth: Int = .max,
        skippedNames: Set<String> = [],
        shouldContinue: (() throws -> Bool)? = nil
    ) throws -> HeadlessSecureEnumerationResult {
        let entryLimit = max(0, maxEntries)
        let examinedLimit = max(0, maxExaminedEntries ?? maxEntries)
        let perDirectoryLimit = max(0, maxEntriesPerDirectory)
        let depthLimit = max(0, maxDepth)
        let opened = try openNode(root: root, relativePath: relativePath)
        defer { Darwin.close(opened.descriptor) }

        let baseDisplayPath = displayPath(root: root, relativePath: relativePath)
        let baseMetadata = try metadata(from: opened.status, displayPath: baseDisplayPath)
        guard baseMetadata.kind == .directory else {
            return HeadlessSecureEnumerationResult(
                baseMetadata: baseMetadata,
                entries: [],
                examinedEntryCount: 0,
                skippedEntryCount: 0,
                wasTruncated: false
            )
        }

        var entries: [HeadlessSecureEnumerationEntry] = []
        var examinedEntryCount = 0
        var skippedEntryCount = 0
        var wasTruncated = false

        func walk(directoryDescriptor: Int32, parentRelativePath: String, depth: Int) throws {
            guard depth < depthLimit, !wasTruncated else { return }
            let candidates = try directoryCandidates(
                descriptor: directoryDescriptor,
                root: root,
                parentRelativePath: parentRelativePath,
                skippedNames: skippedNames,
                examinedEntryCount: &examinedEntryCount,
                skippedEntryCount: &skippedEntryCount,
                wasTruncated: &wasTruncated,
                maxExaminedEntries: examinedLimit,
                maxEntriesPerDirectory: perDirectoryLimit,
                shouldContinue: shouldContinue
            )

            for candidate in candidates {
                if entries.count >= entryLimit {
                    wasTruncated = true
                    return
                }
                if try shouldContinue?() == false {
                    wasTruncated = true
                    return
                }

                let childRelativePath = parentRelativePath.isEmpty
                    ? candidate.name
                    : "\(parentRelativePath)/\(candidate.name)"
                let isDirectory = candidate.status.st_mode & S_IFMT == S_IFDIR
                let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | (isDirectory ? O_DIRECTORY : 0)
                let childDescriptor = candidate.name.withCString { pointer in
                    Darwin.openat(directoryDescriptor, pointer, flags)
                }
                guard childDescriptor >= 0 else {
                    skippedEntryCount += 1
                    continue
                }

                var openedStatus = stat()
                guard Darwin.fstat(childDescriptor, &openedStatus) == 0 else {
                    skippedEntryCount += 1
                    Darwin.close(childDescriptor)
                    continue
                }
                guard openedStatus.st_dev == candidate.status.st_dev,
                      openedStatus.st_ino == candidate.status.st_ino,
                      openedStatus.st_mode & S_IFMT == candidate.status.st_mode & S_IFMT
                else {
                    skippedEntryCount += 1
                    Darwin.close(childDescriptor)
                    continue
                }

                let childMetadata: HeadlessSecureFileMetadata
                do {
                    childMetadata = try metadata(
                        from: openedStatus,
                        displayPath: displayPath(root: root, relativePath: childRelativePath)
                    )
                } catch {
                    skippedEntryCount += 1
                    Darwin.close(childDescriptor)
                    continue
                }
                componentOpenHook?(childRelativePath, childDescriptor)
                entries.append(HeadlessSecureEnumerationEntry(
                    relativePath: childRelativePath,
                    metadata: childMetadata
                ))
                if childMetadata.kind == .directory {
                    try walk(
                        directoryDescriptor: childDescriptor,
                        parentRelativePath: childRelativePath,
                        depth: depth + 1
                    )
                }
                Darwin.close(childDescriptor)
                if wasTruncated { return }
            }
        }

        try walk(directoryDescriptor: opened.descriptor, parentRelativePath: relativePath, depth: 0)
        return HeadlessSecureEnumerationResult(
            baseMetadata: baseMetadata,
            entries: entries,
            examinedEntryCount: examinedEntryCount,
            skippedEntryCount: skippedEntryCount,
            wasTruncated: wasTruncated
        )
    }

    private struct DirectoryCandidate {
        var name: String
        var status: stat
    }

    private func directoryCandidates(
        descriptor: Int32,
        root: HeadlessAllowedRoot,
        parentRelativePath: String,
        skippedNames: Set<String>,
        examinedEntryCount: inout Int,
        skippedEntryCount: inout Int,
        wasTruncated: inout Bool,
        maxExaminedEntries: Int,
        maxEntriesPerDirectory: Int,
        shouldContinue: (() throws -> Bool)?
    ) throws -> [DirectoryCandidate] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw posixError(
                operation: "duplicate directory descriptor",
                path: displayPath(root: root, relativePath: parentRelativePath),
                errorNumber: errno
            )
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let savedErrno = errno
            Darwin.close(duplicate)
            throw posixError(
                operation: "open directory stream",
                path: displayPath(root: root, relativePath: parentRelativePath),
                errorNumber: savedErrno
            )
        }
        defer { Darwin.closedir(directory) }

        var candidates: [DirectoryCandidate] = []
        var localEntryCount = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if try shouldContinue?() == false {
                wasTruncated = true
                break
            }
            guard examinedEntryCount < maxExaminedEntries,
                  localEntryCount < maxEntriesPerDirectory
            else {
                wasTruncated = true
                break
            }
            examinedEntryCount += 1
            localEntryCount += 1
            guard !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.hasPrefix("."),
                  !name.utf8.contains(0),
                  !skippedNames.contains(name)
            else {
                skippedEntryCount += 1
                continue
            }

            var status = stat()
            let inspectResult = name.withCString { pointer in
                Darwin.fstatat(descriptor, pointer, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard inspectResult == 0 else {
                skippedEntryCount += 1
                continue
            }
            switch status.st_mode & S_IFMT {
            case S_IFDIR, S_IFREG:
                candidates.append(DirectoryCandidate(name: name, status: status))
            default:
                skippedEntryCount += 1
            }
        }
        return candidates.sorted { lhs, rhs in
            let lhsDirectory = lhs.status.st_mode & S_IFMT == S_IFDIR
            let rhsDirectory = rhs.status.st_mode & S_IFMT == S_IFDIR
            if lhsDirectory != rhsDirectory { return lhsDirectory && !rhsDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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
