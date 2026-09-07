import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// All child artifacts are private synthetic data. No credential-provider import,
/// app UI, shared MCP endpoint, or default environment builder participates.
final class SwitchboardControllerRuntimeFixture {
    enum Failure: Error { case unavailable }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    let root: URL
    let workspace: URL
    private let resources: URL
    private var ready: [String: Any] = [:]
    private var stopped = false
    private var preserveArtifacts = false

    var model: String {
        ready["model"] as? String ?? ""
    }

    var marker: String {
        "RP_CONTROLLER_RETAINED_CONTEXT"
    }

    init() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configURL = repository.appendingPathComponent(".build/validation-artifacts/switchboard-controller/config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { throw XCTSkip("Configure the pinned real-runtime integration fixture explicitly.") }
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: String],
              Set(config.keys) == ["resources", "source"], let resourcePath = config["resources"], let source = config["source"] else { throw Failure.unavailable }
        resources = URL(fileURLWithPath: resourcePath)
        root = URL(fileURLWithPath: "/private/tmp/sb-controller-\(UUID().uuidString.prefix(12))")
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bridgeRoot = root.appendingPathComponent("bridge")
        for directory in [workspace, bridgeRoot, root.appendingPathComponent("home"), root.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-I",
            "-B",
            tests.appendingPathComponent("Fixtures/switchboard_controller_runtime_fixture.py").path,
            source,
            String(getpid()),
            bridgeRoot.path,
            "none"
        ]
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
        process.currentDirectoryURL = bridgeRoot
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [exited] _ in exited.signal() }
        do {
            try process.run()
            try output.fileHandleForWriting.close()
            try errors.fileHandleForWriting.close()
            try input.fileHandleForReading.close()
            ready = try readReply()
            guard ready["source_pinned"] as? Bool == true, ready["marker"] as? String == marker, model == "gpt-5.6-sol" else { throw Failure.unavailable }
        } catch {
            finish()
            throw Failure.unavailable
        }
    }

    func configuration() throws -> CodexManagedHTTPIntegrationConfiguration {
        guard let endpoint = ready["responses_url"] as? String else { throw Failure.unavailable }
        let validated = try CodexManagedHTTPIntegrationConfiguration.validatedLoopbackURL(endpoint)
        guard let port = URLComponents(string: validated)?.port else { throw Failure.unavailable }
        let profileURL = root.appendingPathComponent("native.sb")
        let own = try quoted(root.path)
        let runtime = try quoted(resources.path)
        let userHome = try quoted(CodexManagedHTTPIntegrationConfiguration.realUserHomePath())
        // Proven with a native helper: exact port succeeds, another listening
        // port, real home reads and outside writes fail with OS denial.
        let profile = """
        (version 1)
        (allow default)
        (deny network*)
        (allow network-outbound (remote ip "localhost:\(port)"))
        (allow network* (local unix-socket (subpath \(own))) (remote unix-socket (subpath \(own))))
        (deny file-write*)
        (allow file-write* (subpath \(own)) (literal "/dev/null"))
        (deny file-read* (subpath \(userHome)) (subpath "/Library/Keychains"))
        (deny process-exec)
        (allow process-exec (subpath \(own)) (subpath \(runtime)) (subpath "/usr/bin") (subpath "/bin") (literal "/usr/libexec/path_helper"))
        (deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd") (global-name "com.apple.securityd.xpc") (global-name "com.apple.securityd.general") (global-name "com.apple.securityd.systemkeychain") (global-name "com.apple.security.cloudkeychainproxy3") (global-name "com.apple.securityd.ckks") (global-name "com.apple.securityd.kcsharing"))
        """
        try Data(profile.utf8).write(to: profileURL)
        return try .init(resourcesURL: resources, rootURL: root, responsesURL: validated, sandboxProfileURL: profileURL)
    }

    func pairing() throws -> SwitchboardPairingEnvelope {
        guard let object = ready["envelope"] as? [String: Any] else { throw Failure.unavailable }
        return try .parse(JSONSerialization.data(withJSONObject: object))
    }

    func writeSafeConfiguration(to home: URL) throws {
        let text = """
        model="gpt-5.6-sol"
        check_for_update_on_startup=false
        web_search="disabled"
        [features]
        apps=false
        plugins=false
        shell_tool=false
        multi_agent=false
        code_mode=false
        [agents]
        enabled=false
        [analytics]
        enabled=false
        """
        try Data(text.utf8).write(to: home.appendingPathComponent("config.toml"))
    }

    func command(_ op: String) throws -> [String: Any] {
        var bytes = try JSONSerialization.data(withJSONObject: ["op": op])
        bytes.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: bytes)
        return try readReply()
    }

    private func readReply() throws -> [String: Any] {
        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
        var bytes = Data()
        while bytes.count < 65536 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw Failure.unavailable }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&event, 1, Int32((deadline - now + 999_999) / 1_000_000)) > 0 else { throw Failure.unavailable }
            var byte: UInt8 = 0
            guard Darwin.read(descriptor, &byte, 1) == 1 else { throw Failure.unavailable }
            if byte == 0x0A {
                guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], value["error"] == nil else { throw Failure.unavailable }
                return value
            }
            bytes.append(byte)
        }
        throw Failure.unavailable
    }

    private func quoted(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let string = try String(data: encoder.encode(value), encoding: .utf8) else { throw Failure.unavailable }
        return string
    }

    func preservePreAuthFailureArtifacts() {
        preserveArtifacts = true
        print("Synthetic pre-auth fixture diagnostics retained at \(root.path)")
    }

    func finish() {
        guard !stopped else { return }
        stopped = true
        if process.isRunning { _ = try? command("stop") }
        if process.processIdentifier > 0, exited.wait(timeout: .now() + 2) != .success {
            if process.isRunning { process.terminate() }
            XCTAssertEqual(exited.wait(timeout: .now() + 2), .success, "Owned synthetic fixture did not stop")
        }
        if !process.isRunning, process.processIdentifier > 0 {
            XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty, "Synthetic fixture emitted unexpected stderr")
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        if !preserveArtifacts { try? FileManager.default.removeItem(at: root) }
    }
}
