//
//  OutputSink.swift
//  repoprompt-mcp
//
//  Abstraction for command output - stdout or file redirect.
//

import Foundation

/// Manages where command output goes - stdout or file redirect.
enum OutputSink {
    case stdout
    case file(path: String, handle: FileHandle)

    /// Writes a line of text to the sink.
    mutating func writeLine(_ text: String) {
        switch self {
        case .stdout:
            print(text)
        case let .file(path, handle):
            let data = (text + "\n").data(using: .utf8) ?? Data()
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Fallback to stdout on write failure
                fputs("Error writing to \(path): \(error)\n", Darwin.stderr)
                print(text)
            }
        }
    }

    /// Writes text without a trailing newline.
    mutating func write(_ text: String) {
        switch self {
        case .stdout:
            print(text, terminator: "")
            fflush(Darwin.stdout)
        case let .file(_, handle):
            if let data = text.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    /// Opens a file for redirect.
    /// - Parameters:
    ///   - path: File path to write to
    ///   - append: If true, appends to existing content (`>>`). If false, truncates (`>`).
    /// - Returns: A new OutputSink.file if successful.
    static func openFile(at path: String, append: Bool = false) throws -> OutputSink {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            // Create parent directories if needed
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        if append {
            handle.seekToEndOfFile()
        } else {
            // Truncate file for shell-like `>` behavior
            try handle.truncate(atOffset: 0)
        }
        return .file(path: path, handle: handle)
    }

    /// Closes the file handle if this is a file sink.
    mutating func close() {
        if case let .file(_, handle) = self {
            try? handle.close()
        }
        self = .stdout
    }

    /// Returns true if currently redirecting to a file.
    var isRedirecting: Bool {
        if case .file = self { return true }
        return false
    }
}

/// Settings that control command runner behavior.
struct RunnerSettings {
    var prettyJSON: Bool = true
    var colors: Bool = false
    var verbose: Bool = false
    var timing: Bool = false
    var failFast: Bool = false // Stop on first failure even for ';'

    enum ExitCodeMode {
        case anyFailure // If any segment fails => non-zero
        case lastSegment // Shell-like: exit code follows last executed segment
    }

    var exitCodeMode: ExitCodeMode = .anyFailure
}

/// Summary of executing a single input line.
struct LineExecutionResult {
    let line: String
    let succeeded: Bool
    let failedSegments: Int
    let totalSegments: Int
}
