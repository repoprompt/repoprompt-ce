import Darwin
import Foundation
import RepoPromptCore

package struct MacOSWorkspaceFileMutationBackend: WorkspaceFileMutationBackend {
    package init() {}

    package func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    package func createFile(at url: URL, contents: Data?) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    package func write(_ data: Data, to url: URL, atomically: Bool) throws {
        if !atomically {
            try data.write(to: url)
            return
        }
        do {
            try data.write(to: url, options: [.atomic])
            return
        } catch {}

        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".repoprompt.tmp.\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temporaryURL, to: url)
            return
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
        }
        try writePOSIX(data, to: url)
    }

    package func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    package func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    package func trashItem(at url: URL) throws {
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
    }

    package func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        var value = ObjCBool(isDirectory)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &value)
        isDirectory = value.boolValue
        return exists
    }

    package func isWritableFile(atPath path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path)
    }

    package func isSymbolicLink(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    package func modificationDate(at url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date ?? Date()
    }

    private func writePOSIX(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var firstError: Int32?
        data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, base, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    firstError = errno
                    break
                }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
        if firstError == nil, fsync(descriptor) != 0 {
            firstError = errno
        }
        if Darwin.close(descriptor) != 0, firstError == nil {
            firstError = errno
        }
        if let firstError {
            throw POSIXError(POSIXErrorCode(rawValue: firstError) ?? .EIO)
        }
    }
}
