import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// All child artifacts are private synthetic data. No credential-provider import,
/// app UI, shared MCP endpoint, or default environment builder participates.
final class SwitchboardControllerRuntimeFixture {
    enum Mode { case manual, automatic }
    enum Failure: Error { case unavailable, stage(String) }
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
    private let mode: Mode
    private let nativeHash: String?
    private let metadataHash: String?
    private let interpreterExecutable: URL?
    private let interpreterHash: String?
    private var helperIdentity: OwnedIdentity?

    var model: String {
        ready["model"] as? String ?? ""
    }

    var marker: String {
        "RP_CONTROLLER_RETAINED_CONTEXT"
    }

    init(mode: Mode = .manual) throws {
        self.mode = mode
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configurationName = mode == .manual ? "switchboard-controller" : "switchboard-automatic-controller"
        let configURL = repository.appendingPathComponent(".build/validation-artifacts/\(configurationName)/config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { throw XCTSkip("Configure the pinned real-runtime integration fixture explicitly.") }
        let fields: Set<String> = mode == .manual ? ["resources", "source"] : [
            "resources", "source", "native_sha256", "metadata_sha256", "python", "python_sha256"
        ]
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: String],
              Set(config.keys) == fields, let resourcePath = config["resources"], let source = config["source"] else { throw Failure.unavailable }
        nativeHash = config["native_sha256"]
        metadataHash = config["metadata_sha256"]
        interpreterExecutable = config["python"].map { URL(fileURLWithPath: $0) }
        interpreterHash = config["python_sha256"]
        resources = URL(fileURLWithPath: resourcePath)
        root = URL(fileURLWithPath: "/private/tmp/sb-controller-\(UUID().uuidString.prefix(12))")
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bridgeRoot = root.appendingPathComponent("bridge")
        for directory in [workspace, bridgeRoot, root.appendingPathComponent("home"), root.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        process.executableURL = interpreterExecutable ?? URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-I",
            "-B",
            tests.appendingPathComponent(mode == .manual ? "Fixtures/switchboard_controller_runtime_fixture.py" : "Fixtures/switchboard_automatic_runtime_fixture.py").path,
            source,
            String(getpid()),
            bridgeRoot.path,
            "none"
        ]
        if mode == .automatic { process.arguments?.append(resources.path) }
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
        if mode == .automatic {
            process.environment?["HOME"] = root.appendingPathComponent("home").path
            process.environment?["SWITCHBOARD_HOME"] = bridgeRoot.path
        }
        process.currentDirectoryURL = bridgeRoot
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [exited] _ in exited.signal() }
        do {
            if mode == .automatic {
                guard let interpreterExecutable, let interpreterHash,
                      interpreterExecutable.path.hasPrefix("/"),
                      interpreterExecutable.resolvingSymlinksInPath().path == interpreterExecutable.path,
                      try digest(interpreterExecutable) == interpreterHash else { throw Failure.unavailable }
            }
            try process.run()
            if mode == .automatic {
                guard let interpreterExecutable else { throw Failure.unavailable }
                let launched = try OwnedIdentity.capture(process.processIdentifier)
                helperIdentity = launched
                guard launched.executable == interpreterExecutable.path else { throw Failure.unavailable }
            }
            try output.fileHandleForWriting.close()
            try errors.fileHandleForWriting.close()
            try input.fileHandleForReading.close()
            ready = try readReply()
            guard ready["source_pinned"] as? Bool == true, ready["marker"] as? String == marker, model == "gpt-5.6-sol" else { throw Failure.unavailable }
            if mode == .automatic {
                let settled = try OwnedIdentity.capture(process.processIdentifier)
                guard let interpreterExecutable, let interpreterHash,
                      settled.sameProcess(as: helperIdentity), settled.uid == getuid(), settled.parent == getpid(),
                      settled.executable == interpreterExecutable.path,
                      try digest(interpreterExecutable) == interpreterHash else { throw Failure.unavailable }
                helperIdentity = settled
            }
        } catch let error as Failure {
            finish()
            throw error
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
        let profile = mode == .automatic ? try automaticProfile(port: port, own: own, userHome: userHome) : """
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
        let configuration = try CodexManagedHTTPIntegrationConfiguration(resourcesURL: resources, rootURL: root, responsesURL: validated, sandboxProfileURL: profileURL)
        if mode == .automatic { try verifyNative(configuration) }
        return configuration
    }

    private var nativeExecutable: URL {
        resources.appendingPathComponent("BundledRuntimes/Codex/aarch64-apple-darwin/bin/codex")
    }

    private func automaticProfile(port: Int, own: String, userHome: String) throws -> String {
        let executable = try quoted(nativeExecutable.path)
        let shared = "repoprompt-ce-mcp-\(getuid())"
        return """
        (version 1)
        (allow default)
        (deny network*)
        (allow network-outbound (remote ip "localhost:\(port)"))
        (allow network* (local unix-socket (subpath \(own))) (remote unix-socket (subpath \(own))))
        (deny file-write*)
        (allow file-write* (subpath \(own)) (literal "/dev/null"))
        (deny file-read* (subpath \(userHome)) (subpath "/Library/Keychains")
          (subpath "/private/var/Keychains") (subpath "/var/Keychains")
          (subpath "/private/var/folders") (subpath "/var/folders")
          (subpath "/tmp/\(shared)") (subpath "/private/tmp/\(shared)")
          (literal "/.mcp.json") (literal "/tmp/.mcp.json")
          (literal "/private/.mcp.json") (literal "/private/tmp/.mcp.json"))
        (deny process-exec)
        (allow process-exec (literal \(executable)))
        (deny signal)
        (deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd") (global-name "com.apple.securityd.xpc") (global-name "com.apple.securityd.general") (global-name "com.apple.securityd.systemkeychain") (global-name "com.apple.security.cloudkeychainproxy3") (global-name "com.apple.securityd.ckks") (global-name "com.apple.securityd.kcsharing"))
        """
    }

    private func verifyNative(_ configuration: CodexManagedHTTPIntegrationConfiguration) throws {
        let metadata = nativeExecutable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("codex-package.json")
        guard let nativeHash, let metadataHash,
              try digest(nativeExecutable) == nativeHash, try digest(metadata) == metadataHash,
              try configuration.resolve().runtime?.executableURL.path == nativeExecutable.path else { throw Failure.unavailable }
        let version = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let done = DispatchSemaphore(value: 0)
        version.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        version.arguments = ["-f", configuration.sandboxProfileURL.path, nativeExecutable.path, "--version"]
        version.environment = configuration.environment
        version.currentDirectoryURL = root
        version.standardInput = FileHandle.nullDevice
        version.standardOutput = stdout
        version.standardError = stderr
        version.terminationHandler = { _ in done.signal() }
        try version.run()
        let birth = try? OwnedIdentity.capture(version.processIdentifier)
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + 5) == .success else {
            let expected = birth.map { $0.replacingExecutable(nativeExecutable.path) }
            if !terminateOwned(version, identity: expected, exited: done) {
                preserveArtifacts = true
                XCTFail("Exact native version process cleanup could not be confirmed")
            }
            throw Failure.unavailable
        }
        guard version.terminationStatus == 0,
              stdout.fileHandleForReading.readDataToEndOfFile() == Data("codex-cli 0.149.0\n".utf8),
              stderr.fileHandleForReading.readDataToEndOfFile().isEmpty,
              try digest(nativeExecutable) == nativeHash, try digest(metadata) == metadataHash else { throw Failure.unavailable }
    }

    private func digest(_ file: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    private struct OwnedIdentity: Equatable {
        let pid: Int32
        let parent: Int32
        let uid: uid_t
        let start: SwitchboardPairingEnvelope.ProcessStart
        let executable: String

        static func capture(_ pid: Int32) throws -> Self {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw Failure.unavailable }
            var path = [UInt8](repeating: 0, count: 4096)
            guard path.withUnsafeMutableBytes({ proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }) > 0,
                  let executable = String(bytes: path.prefix { $0 != 0 }, encoding: .utf8) else { throw Failure.unavailable }
            return .init(
                pid: pid,
                parent: Int32(info.pbi_ppid),
                uid: info.pbi_uid,
                start: .init(seconds: Int64(info.pbi_start_tvsec), microseconds: Int64(info.pbi_start_tvusec)),
                executable: executable
            )
        }

        func sameProcess(as other: Self?) -> Bool {
            guard let other else { return false }
            return pid == other.pid && parent == other.parent && uid == other.uid && start == other.start
        }

        func replacingExecutable(_ executable: String) -> Self {
            .init(pid: pid, parent: parent, uid: uid, start: start, executable: executable)
        }
    }

    private func terminateOwned(_ process: Process, identity: OwnedIdentity?, exited: DispatchSemaphore) -> Bool {
        if !process.isRunning { return true }
        guard let identity, identity.uid == getuid(), identity.parent == getpid(),
              (try? OwnedIdentity.capture(process.processIdentifier)) == identity else { return false }
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .success { return !process.isRunning }
        guard (try? OwnedIdentity.capture(process.processIdentifier)) == identity else { return !process.isRunning }
        guard Darwin.kill(process.processIdentifier, SIGKILL) == 0 else { return !process.isRunning }
        return exited.wait(timeout: .now() + 2) == .success && !process.isRunning
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
        [mcp_servers.synthetic-third-party]
        command="/bin/false"
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
                guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.unavailable }
                if value["error"] != nil {
                    let allowed = Set([
                        "helper_integrity", "interpreter", "arguments", "source_integrity", "source_load",
                        "source_load_config", "source_load_rotation_rules", "source_load_repoprompt_bridge",
                        "source_load_global_rotation_wire", "source_load_global_rotation", "private_state",
                        "loopback_server", "bridge_server", "pairing", "ready", "commands"
                    ])
                    guard let stage = value["stage"] as? String, allowed.contains(stage) else { throw Failure.unavailable }
                    throw Failure.stage(stage)
                }
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
            if mode == .automatic {
                if !terminateOwned(process, identity: helperIdentity, exited: exited) {
                    preserveArtifacts = true
                    XCTFail("Exact helper identity/exit unconfirmed; private root retained")
                }
            } else {
                if process.isRunning { process.terminate() }
                XCTAssertEqual(exited.wait(timeout: .now() + 2), .success, "Owned synthetic fixture did not stop")
            }
        }
        if !process.isRunning, process.processIdentifier > 0 {
            XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty, "Synthetic fixture emitted unexpected stderr")
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        if mode == .automatic, process.isRunning { preserveArtifacts = true }
        if !preserveArtifacts { try? FileManager.default.removeItem(at: root) }
    }
}
