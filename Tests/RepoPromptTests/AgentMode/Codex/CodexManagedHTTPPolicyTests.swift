import Darwin
@testable import RepoPromptApp
import XCTest

final class CodexManagedHTTPPolicyTests: XCTestCase {
    func testEveryProviderWorkMethodCarriesExactRevocableFrameAuthority() throws {
        for method in ["turn/start", "turn/steer", "review/start", "thread/compact/start", "thread/shellCommand"] {
            var gate = CodexManagedHTTPPolicy.RequestGate()
            try gate.claimStartup()
            try gate.bindThread("owned")
            let lease = try gate.reserve()
            let authorization = CodexAccountAdoptionAuthorization()
            try gate.bindAuthorization(authorization)
            gate.finish(lease, allowTurns: true)
            let frameAuthority = try XCTUnwrap(gate.authorize(method: method))
            XCTAssertTrue(frameAuthority === authorization, method)
            authorization.invalidate()
            var wrote = false
            XCTAssertThrowsError(try frameAuthority.withAuthorization { wrote = true })
            XCTAssertFalse(wrote, method)
            XCTAssertNil(try gate.authorize(method: "turn/interrupt"))
            XCTAssertNil(try gate.authorize(method: "thread/read"))
        }
    }

    func testPrivilegedWriteIsNonblockingAndRestoresFlagsOnFailure() throws {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let original = fcntl(descriptor, F_GETFL)
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.withNonblockingPipeWrite(descriptor: descriptor) {
            XCTAssertNotEqual(fcntl(descriptor, F_GETFL) & O_NONBLOCK, 0)
            throw CodexAccountAdoptionReason.revoked
        })
        XCTAssertEqual(fcntl(descriptor, F_GETFL), original)
    }

    func testReservationRefusesOtherNativeMutators() throws {
        var gate = CodexManagedHTTPPolicy.RequestGate()
        try gate.claimStartup()
        try gate.bindThread("owned")
        _ = try gate.reserve()
        XCTAssertThrowsError(try gate.authorize(method: "thread/rollback"))
        XCTAssertThrowsError(try gate.authorize(method: "command/exec"))
        try gate.authorize(method: "thread/read")
        try gate.authorize(method: "turn/interrupt")
    }

    func testFutureBundledRuntimeDoesNotInheritReviewedTransportProof() throws {
        try CodexManagedHTTPPolicy.verifyRuntimeVersion("0.149.0", bundledVersion: "0.149.0")
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyRuntimeVersion("0.150.0", bundledVersion: "0.150.0"))
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyRuntimeVersion("0.149.0", bundledVersion: "0.150.0"))
    }

    func testPinnedRuntimeEffectiveConfigurationFixture() throws {
        try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(CodexManagedHTTPRuntimeFixture.configuration())
    }

    func testOnlyEffectiveHTTPAndEphemeralConfigurationIsEligible() throws {
        try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(Self.validConfiguration())
        for (key, value) in [
            ("supports_websockets", true as Any),
            ("requires_openai_auth", false as Any),
            ("base_url", "https://example.invalid" as Any),
            ("wire_api", "chat" as Any)
        ] {
            var response = Self.validConfiguration()
            var config = try XCTUnwrap(response["config"] as? [String: Any])
            var provider = Self.provider
            provider[key] = value
            config["model_providers"] = [CodexManagedHTTPPolicy.providerID: provider]
            response["config"] = config
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(response))
        }
        for store in ["file", "keyring", "auto"] {
            var response = Self.validConfiguration()
            var config = try XCTUnwrap(response["config"] as? [String: Any])
            config["cli_auth_credentials_store"] = store
            response["config"] = config
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(response))
        }
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyEffectiveConfiguration([:]))
    }

    func testProviderHeadersTokensUnknownOptionsAndBooleanImpersonatorsRefuse() throws {
        for (key, value) in [
            ("http_headers", ["Authorization": "synthetic"] as Any),
            ("env_key", "SYNTHETIC_KEY" as Any),
            ("unknown_option", NSNull() as Any),
            ("supports_websockets", 0 as Any)
        ] {
            var provider = Self.provider
            provider[key] = value
            var config = try XCTUnwrap(Self.validConfiguration()["config"] as? [String: Any])
            config["model_providers"] = [CodexManagedHTTPPolicy.providerID: provider]
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(["config": config]))
        }
    }

    func testProfilesCannotBypassTransportOrEnableAutonomousGoals() throws {
        for extra in [
            ["profiles": ["example": ["model_provider": "other"]]],
            ["features": ["goals": true]],
            ["profiles": ["mcp_servers": ["base_url": "https://example.invalid"]]]
        ] as [[String: Any]] {
            var config = try XCTUnwrap(Self.validConfiguration()["config"] as? [String: Any])
            config.merge(extra) { _, new in new }
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(["config": config]))
        }
    }

    func testOrdinaryMCPConfigurationAndReasoningRemainAllowed() throws {
        var config = try XCTUnwrap(Self.validConfiguration()["config"] as? [String: Any])
        config["mcp_servers"] = ["example": ["http_headers": ["Authorization": "synthetic-tool-only"]]]
        config["model_reasoning_effort"] = "high"
        try CodexManagedHTTPPolicy.verifyEffectiveConfiguration(["config": config])
        let input: [String: Any] = ["threadId": "original", "config": ["model_reasoning_effort": "high"]]
        let result = try CodexManagedHTTPPolicy.requestParameters(method: "thread/resume", params: input)
        XCTAssertEqual(result?["threadId"] as? String, "original")
        XCTAssertEqual(result?["modelProvider"] as? String, CodexManagedHTTPPolicy.providerID)
    }

    func testRequestGateRejectsAuthRouteGoalAndNestedConfigMutations() {
        for (method, params) in [
            ("account/logout", [:]), ("account/login/start", ["type": "chatgpt"]),
            ("thread/goal/set", ["objective": "test"]),
            ("thread/start", ["modelProvider": "other"]),
            ("thread/resume", ["config": ["model.providers": ["other": [:]]]]),
            ("config/value/write", ["keyPath": "features.goals", "value": true]),
            ("config/batchWrite", ["edits": [["keyPath": "model_provider", "value": "other"]]])
        ] as [(String, [String: Any])] {
            XCTAssertThrowsError(try CodexManagedHTTPPolicy.requestParameters(method: method, params: params))
        }
    }

    func testOnlyExplicitInternalExternalTokenLoginPassesAuthGate() throws {
        XCTAssertNoThrow(try CodexManagedHTTPPolicy.requestParameters(
            method: "account/login/start", params: ["type": "chatgptAuthTokens"], permitsAccountLogin: true
        ))
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.requestParameters(
            method: "account/login/start", params: ["type": "chatgpt"], permitsAccountLogin: true
        ))
    }

    func testLaunchPolicyIgnoresInheritedAuthAndPinsEphemeralStorage() {
        let source = [
            "OPENAI_API_KEY": "synthetic",
            "CODEX_ACCESS_TOKEN": "synthetic",
            "OPENAI_BASE_URL": "https://example.invalid",
            "CODEX_HOME": "/synthetic/owned",
            "CODEX_SQLITE_HOME": "/synthetic/owned/db",
            "PATH": "/usr/bin"
        ]
        let environment = CodexManagedHTTPPolicy.environment(source)
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["CODEX_ACCESS_TOKEN"])
        XCTAssertNil(environment["OPENAI_BASE_URL"])
        XCTAssertEqual(environment["CODEX_HOME"], source["CODEX_HOME"])
        XCTAssertEqual(environment["CODEX_SQLITE_HOME"], source["CODEX_SQLITE_HOME"])
        XCTAssertTrue(CodexManagedHTTPPolicy.launchArguments.contains("cli_auth_credentials_store=\"ephemeral\""))
        XCTAssertTrue(CodexManagedHTTPPolicy.launchArguments.contains("features.goals=false"))
    }

    func testEscapedRouteKeysAndNativeTraceEnvironmentAreNotAccepted() {
        XCTAssertThrowsError(try CodexManagedHTTPPolicy.requestParameters(
            method: "config/value/write", params: ["keyPath": "\"\\u006dodel_provider\"", "value": "other"]
        ))
        let result = CodexManagedHTTPPolicy.environment([
            "RUST_LOG": "trace", "OTEL_EXPORTER_OTLP_ENDPOINT": "https://example.invalid",
            "SSLKEYLOGFILE": "/synthetic/tls-keys", "CODEX_TRACE_FILE": "/synthetic/trace"
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testActorOwnedGateStopsTurnsUntilAppliedAndRejectsStaleRelease() throws {
        var gate = CodexManagedHTTPPolicy.RequestGate()
        try gate.claimStartup()
        try gate.bindThread("original-thread")
        XCTAssertThrowsError(try gate.authorize(method: "turn/start"))
        let initial = try gate.reserve()
        XCTAssertThrowsError(try gate.reserve())
        try gate.authorize(method: "account/login/start", permitsAccountLogin: true)
        try gate.bindAuthorization(CodexAccountAdoptionAuthorization())
        gate.finish(initial, allowTurns: true)
        try gate.authorize(method: "turn/start")
        let switching = try gate.reserve()
        gate.finish(initial, allowTurns: true)
        XCTAssertThrowsError(try gate.authorize(method: "turn/steer"))
        XCTAssertThrowsError(try gate.authorize(method: "thread/compact/start"))
        gate.finish(switching, allowTurns: false)
        XCTAssertThrowsError(try gate.authorize(method: "turn/start"))
    }

    func testActorOwnedGateNeverRestartsOrRebindsManagedConversation() throws {
        var gate = CodexManagedHTTPPolicy.RequestGate()
        try gate.claimStartup()
        try gate.authorize(method: "thread/start")
        try gate.bindThread("original-thread")
        XCTAssertThrowsError(try gate.claimStartup())
        XCTAssertThrowsError(try gate.bindThread("replacement-thread"))
        XCTAssertEqual(gate.threadID, "original-thread")
        for method in ["thread/start", "thread/resume", "thread/fork", "thread/goal/set"] {
            XCTAssertThrowsError(try gate.authorize(method: method))
        }
        XCTAssertThrowsError(try gate.authorize(method: "account/login/start", permitsAccountLogin: true))
    }

    private static let provider: [String: Any] = [
        "name": "Switchboard managed HTTP", "base_url": CodexManagedHTTPPolicy.baseURL,
        "requires_openai_auth": true, "wire_api": "responses", "supports_websockets": false
    ]

    private static func validConfiguration() -> [String: Any] {
        ["config": [
            "model_provider": CodexManagedHTTPPolicy.providerID,
            "model_providers": [CodexManagedHTTPPolicy.providerID: provider],
            "cli_auth_credentials_store": "ephemeral",
            "features": ["goals": false]
        ]]
    }
}
