import CryptoKit
import Foundation

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
    case unavailable

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: "Downloaded Antigravity runtime failed SHA-256 verification."
        case .invalidArchive: "Downloaded Antigravity runtime archive is invalid."
        case .unavailable: "Antigravity runtime is not installed."
        }
    }
}

actor AntigravityRuntimeManager {
    static let shared = AntigravityRuntimeManager()
    private let fileManager = FileManager.default
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoPrompt CE/Runtimes/antigravity", isDirectory: true)
    }

    static func installedRuntimeSync() -> (command: String, harness: String)? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RepoPrompt CE/Runtimes/antigravity/\(AntigravityRuntimeRelease.current.version)", isDirectory: true)
        let command = root.appendingPathComponent(AntigravityRuntimeRelease.current.executable).path
        let harness = root.appendingPathComponent(AntigravityRuntimeRelease.current.harness).path
        guard FileManager.default.isExecutableFile(atPath: command), FileManager.default.fileExists(atPath: harness) else { return nil }
        return (command, harness)
    }

    func installedRuntime() -> (command: String, harness: String)? {
        let release = AntigravityRuntimeRelease.current
        let directory = root.appendingPathComponent(release.version, isDirectory: true)
        let command = directory.appendingPathComponent(release.executable).path
        let harness = directory.appendingPathComponent(release.harness).path
        guard fileManager.isExecutableFile(atPath: command), fileManager.fileExists(atPath: harness) else { return nil }
        return (command, harness)
    }

    func install(_ release: AntigravityRuntimeRelease = .current) async throws -> (command: String, harness: String) {
        let directory = root.appendingPathComponent(release.version, isDirectory: true)
        if let installed = await installedRuntime() { return installed }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("\(release.version).zip")
        let (data, response) = try await URLSession.shared.data(from: release.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AntigravityRuntimeError.unavailable }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else { throw AntigravityRuntimeError.checksumMismatch }
        try data.write(to: archive, options: .atomic)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.unzip(archive, into: directory)
        try? fileManager.removeItem(at: archive)
        guard fileManager.isExecutableFile(atPath: directory.appendingPathComponent(release.executable).path) else { throw AntigravityRuntimeError.invalidArchive }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent(release.executable).path)
        return (directory.appendingPathComponent(release.executable).path, directory.appendingPathComponent(release.harness).path)
    }

    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AntigravityRuntimeError.invalidArchive }
    }
}
