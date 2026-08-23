import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class CodexDeviceAuthRuntimeTests: XCTestCase {
    func testDesktopCompatibleDeviceFlowPersistsOnlyInManagedHomeAndLogsOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let driver = try fixture.makeDriver()

        let descriptor = await driver.authFlowDescriptor(providerID: .codex, forceRefresh: true)
        XCTAssertEqual(descriptor?.kind, .deviceCodeBeta)
        XCTAssertEqual(descriptor?.startable, true)

        let pending = try await driver.start(providerID: .codex, kind: .deviceCodeBeta)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.userCode, "ABCD-EFGH")
        XCTAssertEqual(pending.verificationURL?.absoluteString, "https://auth.openai.com/codex/device")

        let stillPending = try await driver.poll(flowID: pending.flowID)
        XCTAssertEqual(stillPending.state, .pending)
        XCTAssertTrue(FileManager.default.createFile(atPath: fixture.completionMarker.path, contents: Data()))
        let completed = try await driver.poll(flowID: pending.flowID)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertNil(completed.userCode)
        XCTAssertNil(completed.verificationURL)

        let state = await driver.authenticationState(providerID: .codex)
        XCTAssertEqual(state, .authenticated(accountLabel: "owner@example.com"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.managedHome.codexHome.appendingPathComponent("auth.json").path))

        try await driver.logout(providerID: .codex)
        let loggedOutState = await driver.authenticationState(providerID: .codex)
        XCTAssertEqual(loggedOutState, .notAuthenticated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.managedHome.codexHome.appendingPathComponent("auth.json").path))

        let calls = try fixture.calls()
        XCTAssertTrue(calls.contains { $0.method == "account/login/start" && $0.type == CodexCLIContract.deviceFlowType })
        XCTAssertTrue(calls.contains { $0.method == "account/read" && $0.refreshToken == true })
        XCTAssertTrue(calls.contains { $0.method == "account/logout" })
        XCTAssertTrue(calls.allSatisfy { !$0.apiKeyPresent })
        XCTAssertTrue(calls.allSatisfy { $0.codexHome == fixture.managedHome.codexHome.path })
        XCTAssertTrue(calls.allSatisfy { $0.sqliteHome == fixture.managedHome.sqliteHome.path })
    }

    func testCancelUsesCorrelatedDesktopLoginIDAndRetiresProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let driver = try fixture.makeDriver()
        let pending = try await driver.start(providerID: .codex, kind: .deviceCodeBeta)

        await driver.cancel(flowID: pending.flowID)

        let calls = try fixture.calls()
        XCTAssertEqual(calls.filter { $0.method == "initialize" }.count, 1)
        XCTAssertTrue(calls.contains { $0.method == "account/login/cancel" && $0.loginID == "device-login" })
        do {
            _ = try await driver.poll(flowID: pending.flowID)
            XCTFail("cancelled flow remained available")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testCapabilityRemainsVisibleButUnavailableWhenPinnedVersionDoesNotMatch() async throws {
        let fixture = try Fixture(version: "0.146.0")
        defer { fixture.cleanup() }
        let driver = try fixture.makeDriver()

        let descriptor = await driver.authFlowDescriptor(providerID: .codex, forceRefresh: true)
        XCTAssertEqual(descriptor?.kind, .deviceCodeBeta)
        XCTAssertEqual(descriptor?.startable, false)
        XCTAssertTrue(descriptor?.detail.contains("temporarily unavailable") == true)
    }

    func testModelCatalogUsesPaginatedDesktopAppServerDiscoveryAndExplicitFastTierMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let driver = try fixture.makeDriver()

        let discovered = try await driver.discoverModelCatalog(providerID: .codex, forceRefresh: true)
        let catalog = try XCTUnwrap(discovered)
        XCTAssertEqual(catalog.map(\.id), ["gpt-5.6-luna", "gpt-5.6-luna-fast", "gpt-5.2", "gpt-5.4-mini", "gpt-5.4-mini-fast"])
        XCTAssertEqual(catalog.first?.reasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(catalog.first?.defaultReasoningEffort, "medium")
        XCTAssertEqual(catalog.first?.isProviderDefault, true)

        let fast = try XCTUnwrap(catalog.first { $0.id == "gpt-5.6-luna-fast" })
        XCTAssertEqual(fast.providerRawValue, "gpt-5.6-luna")
        XCTAssertEqual(fast.serviceTier, "fast")
        XCTAssertTrue(fast.displayName.hasSuffix(" Fast"))
        XCTAssertFalse(catalog.contains { $0.id == "gpt-5.2-fast" })

        let listCalls = try fixture.calls().filter { $0.method == "model/list" }
        XCTAssertEqual(listCalls.map(\.cursor), [nil, "page-2"])
        XCTAssertEqual(listCalls.map(\.limit), [100, 100])
    }
}

private struct FixtureCall: Decodable {
    let method: String
    let type: String?
    let refreshToken: Bool?
    let loginID: String?
    let cursor: String?
    let limit: Int?
    let codexHome: String
    let sqliteHome: String
    let apiKeyPresent: Bool
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let executable: URL
    let callsFile: URL
    let completionMarker: URL
    let outputDirectory: URL
    let managedHome: CodexManagedAuthHome
    private let version: String

    init(version: String = CodexCLIContract.pinnedVersion) throws {
        self.version = version
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        executable = root.appendingPathComponent("codex")
        callsFile = root.appendingPathComponent("calls.jsonl")
        completionMarker = root.appendingPathComponent("complete")
        outputDirectory = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        managedHome = try CodexManagedAuthHome(rootPath: root.appendingPathComponent("managed", isDirectory: true).path)
        try makeExecutable()
    }

    func makeDriver() throws -> CodexDeviceAuthDriver {
        CodexDeviceAuthDriver(
            executable: executable.path,
            managedHome: managedHome,
            processPort: try PortableProcessSupervisionPort(),
            outputDirectory: outputDirectory.path,
            // Hosted macOS runners can take several seconds to initialize the
            // fixture app-server under load. Keep the production default intact
            // while allowing this test to exercise the authoritative launch.
            requestTimeout: .seconds(10),
            flowLifetime: .seconds(10)
        )
    }

    func calls() throws -> [FixtureCall] {
        guard FileManager.default.fileExists(atPath: callsFile.path) else { return [] }
        return try String(contentsOf: callsFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(FixtureCall.self, from: Data($0.utf8)) }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeExecutable() throws {
        func literal(_ value: String) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                .replacingOccurrences(of: "\\/", with: "/")
        }
        let script = """
        #!/usr/bin/python3
        import json, os, pathlib, sys
        VERSION = \(try literal(version))
        CALLS = pathlib.Path(\(try literal(callsFile.path)))
        COMPLETE = pathlib.Path(\(try literal(completionMarker.path)))
        if len(sys.argv) > 1 and sys.argv[1] == "--version":
            print("codex-cli " + VERSION)
            raise SystemExit(0)
        if len(sys.argv) < 2 or sys.argv[1] != "app-server":
            raise SystemExit(2)
        codex_home = pathlib.Path(os.environ["CODEX_HOME"])
        auth_file = codex_home / "auth.json"
        for raw in sys.stdin:
            request = json.loads(raw)
            method = request.get("method", "")
            params = request.get("params") or {}
            with CALLS.open("a") as handle:
                handle.write(json.dumps({
                    "method": method,
                    "type": params.get("type"),
                    "refreshToken": params.get("refreshToken"),
                    "loginID": params.get("loginId"),
                    "cursor": params.get("cursor"),
                    "limit": params.get("limit"),
                    "codexHome": os.environ.get("CODEX_HOME", ""),
                    "sqliteHome": os.environ.get("CODEX_SQLITE_HOME", ""),
                    "apiKeyPresent": "OPENAI_API_KEY" in os.environ
                }) + "\\n")
            if "id" not in request:
                continue
            result = {}
            if method == "account/login/start":
                result = {"type":"chatgptDeviceCode", "loginId":"device-login", "userCode":"ABCD-EFGH", "verificationUrl":"https://auth.openai.com/codex/device"}
            elif method == "initialize":
                result = {"userAgent":"repoprompt-server/" + VERSION + " (fixture)"}
            elif method == "account/read":
                if COMPLETE.exists() and not auth_file.exists():
                    codex_home.mkdir(parents=True, exist_ok=True)
                    auth_file.write_text('{"tokens":{"access_token":"server-only-test-token"}}')
                    os.chmod(auth_file, 0o600)
                result = {"requiresOpenaiAuth": True, "account": ({"type":"chatgpt", "email":"owner@example.com", "planType":"pro"} if auth_file.exists() else None)}
            elif method == "model/list":
                if params.get("cursor") == "page-2":
                    result = {"data":[
                        {"id":"gpt-5.4-mini", "model":"gpt-5.4-mini", "displayName":"GPT-5.4 Mini", "description":"Compact model", "isDefault":False, "supportedReasoningEfforts":[{"reasoningEffort":"low"}], "defaultReasoningEffort":"low"}
                    ]}
                else:
                    result = {"data":[
                        {"id":"gpt-5.6-luna", "model":"gpt-5.6-luna", "displayName":"GPT-5.6 Luna", "description":"Default model", "isDefault":True, "supportedReasoningEfforts":[{"reasoningEffort":"high"}, {"reasoningEffort":"low"}], "defaultReasoningEffort":"medium"},
                        {"id":"gpt-5.2", "model":"gpt-5.2", "displayName":"GPT-5.2", "description":"Earlier model", "isDefault":False, "supportedReasoningEfforts":[], "defaultReasoningEffort":None}
                    ], "nextCursor":"page-2"}
            elif method == "account/login/cancel":
                pass
            elif method == "account/logout":
                if auth_file.exists(): auth_file.unlink()
                if COMPLETE.exists(): COMPLETE.unlink()
            print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":result}), flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
}
