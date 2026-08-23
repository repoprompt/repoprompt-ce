import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel

public actor LocalProjectSourceGitRunner: ProjectSourceGitRunning {
    public init() {}

    public func run(_ invocation: ProjectSourceGitInvocation) async throws -> String {
        let outputURL = URL(fileURLWithPath: invocation.outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory, isDirectory: true)
        process.standardOutput = output
        process.standardError = output
        try process.run()

        let deadline = Date().addingTimeInterval(TimeInterval(invocation.timeoutSeconds))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                let outputBytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if Date() >= deadline
                    || outputBytes > invocation.maximumOutputBytes
                    || directorySize(at: invocation.observedDirectory) > invocation.maximumDirectoryBytes
                {
                    await terminate(process)
                    throw ServiceAPIError(
                        code: .dependencyUnavailable,
                        message: "Git project source operation exceeded its resource limit"
                    )
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            await terminate(process)
            throw error
        }
        // Polling `isRunning` above has already observed and reaped normal exit.
        // A second `waitUntilExit()` can block in Foundation's shared child-status path.
        try output.synchronize()
        let data = try Data(contentsOf: outputURL)
        guard data.count <= invocation.maximumOutputBytes, process.terminationStatus == 0 else {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "Git project source operation failed"
            )
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Foundation children can inherit the Swift runtime's blocked signal mask on Linux.
    /// Keep termination bounded: request graceful exit, then use the unblockable signal
    /// before returning control to a canceled or resource-limited operation.
    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0 ..< 20 {
            guard process.isRunning else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard process.isRunning else { return }
        #if canImport(Darwin)
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #elseif canImport(Glibc)
            _ = Glibc.kill(process.processIdentifier, SIGKILL)
        #endif
        for _ in 0 ..< 20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func directorySize(at path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
