import CryptoKit
import Foundation
import RepoPromptProcess

struct AntigravityRuntimeRelease: Codable, Equatable {
    let version: String
    let url: URL
    let sha256: String
    let executable: String
    let harness: String

    static let current = AntigravityRuntimeRelease(
        version: "agy_acp_server_1.1.1",
        url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-agy_acp_server_1.1.1-darwin-arm64.zip")!,
        sha256: "fdfa915652cdb7ba8085cc8fffed072cbe009251aa2c951aabdda07a8c28a189",
        executable: "agy_acp_server.par",
        harness: "localharness_external"
    )
}

enum AntigravityRuntimeError: LocalizedError {
    case checksumMismatch
    case invalidArchive
    case extractionTimedOut
    case unavailable

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: "Downloaded Antigravity runtime failed SHA-256 verification."
        case .invalidArchive: "Downloaded Antigravity runtime archive is invalid."
        case .extractionTimedOut: "Antigravity runtime extraction timed out."
        case .unavailable: "Antigravity runtime is not installed."
        }
    }
}

actor AntigravityRuntimeManager {
    static let shared = AntigravityRuntimeManager()
    private let fileManager = FileManager.default
    private let root: URL
    private let download: @Sendable (URL) async throws -> (Data, URLResponse)
    private let extractArchive: @Sendable (URL, URL) async throws -> Void

    init(
        root: URL? = nil,
        download: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) },
        extractArchive: @escaping @Sendable (URL, URL) async throws -> Void = { try await AntigravityRuntimeManager.unzip($0, into: $1) }
    ) {
        self.root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoPrompt CE/Runtimes/antigravity", isDirectory: true)
        self.download = download
        self.extractArchive = extractArchive
    }

    static func installedRuntimeSync() -> (command: String, harness: String)? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RepoPrompt CE/Runtimes/antigravity/\(AntigravityRuntimeRelease.current.version)", isDirectory: true)
        return installedRuntime(in: root, release: .current)
    }

    func installedRuntime(_ release: AntigravityRuntimeRelease = .current) -> (command: String, harness: String)? {
        let directory = root.appendingPathComponent(release.version, isDirectory: true)
        return Self.installedRuntime(in: directory, release: release)
    }

    private static func installedRuntime(in directory: URL, release: AntigravityRuntimeRelease) -> (command: String, harness: String)? {
        let command = directory.appendingPathComponent(release.executable)
        let harness = directory.appendingPathComponent(release.harness)
        guard [command, harness].allSatisfy({ url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isExecutableFile(atPath: url.path)
        }) else { return nil }
        return (command.path, harness.path)
    }

    func install(_ release: AntigravityRuntimeRelease = .current) async throws -> (command: String, harness: String) {
        try Task.checkCancellation()
        if let installed = installedRuntime(release) { return installed }
        let directory = root.appendingPathComponent(release.version, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("runtime.zip")
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        let (data, response) = try await download(release.url)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AntigravityRuntimeError.unavailable }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else { throw AntigravityRuntimeError.checksumMismatch }
        try data.write(to: archive, options: .atomic)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: false)
        try await extractArchive(archive, payload)
        try Task.checkCancellation()
        guard Self.installedRuntime(in: payload, release: release) != nil else { throw AntigravityRuntimeError.invalidArchive }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.appendingPathComponent(release.executable).path)
        // Extraction suspends the actor. Another attempt may have published this release;
        // keep its complete runtime and remove only this attempt's private staging directory.
        if let installed = installedRuntime(release) { return installed }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.moveItem(at: payload, to: directory)
        return (directory.appendingPathComponent(release.executable).path, directory.appendingPathComponent(release.harness).path)
    }

    private static func unzip(_ archive: URL, into directory: URL) async throws {
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "/usr/bin/unzip", processPurpose: .tool,
            workingDirectory: directory.path, shellLookupMode: .disabled
        ))
        let result = try await runner.run(
            args: ["-q", "-o", archive.path, "-d", directory.path], stdin: nil,
            outputMode: .none, timeout: 300, cancelChildOnTaskCancellation: true
        )
        guard !result.timedOut else { throw AntigravityRuntimeError.extractionTimedOut }
        guard result.status == 0 else { throw AntigravityRuntimeError.invalidArchive }
    }
}
