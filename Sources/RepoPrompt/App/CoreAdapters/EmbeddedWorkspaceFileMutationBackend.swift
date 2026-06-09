import Darwin
import Foundation
import RepoPromptCore

struct EmbeddedWorkspaceFileMutationBackend: WorkspaceFileMutationBackend {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createFile(at url: URL, contents: Data?) throws {
        try writeRobust(contents ?? Data(), to: url, atomically: true)
    }

    func write(_ data: Data, to url: URL, atomically: Bool) throws {
        try writeRobust(data, to: url, atomically: atomically)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
    }

    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        var value = ObjCBool(isDirectory)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &value)
        isDirectory = value.boolValue
        return exists
    }

    func modificationDate(at url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date ?? Date()
    }

    private func writeRobust(_ data: Data, to url: URL, atomically: Bool) throws {
        if !atomically {
            try data.write(to: url)
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            return
        } catch {
            // External and network volumes can reject Foundation replacement semantics.
        }

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

    private func writePOSIX(_ data: Data, to url: URL) throws {
        let path = url.path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw posixError(operation: "open", path: path, code: errno)
        }

        var operationError: Int32?
        data.withUnsafeBytes { buffer in
            guard var baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, baseAddress, remaining)
                if written < 0 {
                    operationError = errno
                    break
                }
                remaining -= written
                baseAddress = baseAddress.advanced(by: written)
            }
        }
        if operationError == nil, fsync(descriptor) != 0 {
            operationError = errno
        }
        let closeResult = close(descriptor)
        if let operationError {
            throw posixError(operation: "write/fsync", path: path, code: operationError)
        }
        if closeResult != 0 {
            throw posixError(operation: "close", path: path, code: errno)
        }
    }

    private func posixError(operation: String, path: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(path) (\(code))"]
        )
    }
}
