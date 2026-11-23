import Foundation
import RepoPromptAIContracts
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptCodexProvider
import XCTest

final class CodexNativeInstructionPolicyTests: XCTestCase {
    private typealias Version = CodexRuntimeAuthority.Version

    /// Bumping the bundled runtime must not silently revert new threads to the replacement base.
    func testNativeInstructionFloorCoversBundledRuntime() {
        XCTAssertTrue(CodexNativeSessionController.supportsNativeModelInstructions(CodexRuntimeAuthority.bundledVersion))
    }

    func testNativeInstructionFloorIsAMinimumNotAnExactPin() {
        let floor = CodexNativeSessionController.nativeModelInstructionsMinimumVersion
        XCTAssertTrue(CodexNativeSessionController.supportsNativeModelInstructions(floor))
        XCTAssertTrue(CodexNativeSessionController.supportsNativeModelInstructions(Version(major: 0, minor: 170, patch: 1)))
        XCTAssertTrue(CodexNativeSessionController.supportsNativeModelInstructions(Version(major: 0, minor: 171, patch: 0)))
        XCTAssertTrue(CodexNativeSessionController.supportsNativeModelInstructions(Version(major: 1, minor: 0, patch: 0)))
        XCTAssertFalse(CodexNativeSessionController.supportsNativeModelInstructions(Version(major: 0, minor: 169, patch: 9)))
        XCTAssertFalse(CodexNativeSessionController.supportsNativeModelInstructions(CodexRuntimeAuthority.minimumExternalVersion))
    }

    func testConfiguredDeveloperInstructionsAreAppendedToNote() {
        let compose = CodexNativeSessionController.composeDeveloperInstructions
        XCTAssertEqual(compose("note", nil), "note")
        XCTAssertEqual(compose("note", " \n"), "note")
        XCTAssertEqual(compose("note", "\nUse tabs.\n"), "note\n\nUse tabs.")
    }

    func testConfiguredDeveloperInstructionsAreReadFromEffectiveConfig() {
        let read = CodexNativeSessionController.configuredDeveloperInstructions(fromConfigRead:)
        XCTAssertEqual(read(["config": ["developer_instructions": "Use tabs."]]), "Use tabs.")
        XCTAssertNil(read(["config": ["developer_instructions": NSNull()]]))
        XCTAssertNil(read(["config": [String: Any]()]))
        XCTAssertNil(read([:]))
    }

    func testThreadInstructionResolution() {
        let floor = CodexNativeSessionController.nativeModelInstructionsMinimumVersion
        let old = Version(major: 0, minor: 169, patch: 0)
        func resolve(
            _ existing: CodexThreadInstructionMode??,
            offered: String? = "note",
            bundled: Bool = true,
            version: Version = floor
        ) -> CodexNativeSessionController.ThreadInstructionResolution {
            CodexNativeSessionController.resolveThreadInstructions(
                existing: existing.map { CodexNativeSessionController.SessionRef(conversationID: "thread", instructionMode: $0) },
                offeredDeveloperInstructions: offered,
                isBundledRuntime: bundled,
                runtimeVersion: version
            )
        }
        typealias Resolution = CodexNativeSessionController.ThreadInstructionResolution
        // New threads: native only when offered and supported, on bundled or external runtimes.
        XCTAssertEqual(resolve(nil), Resolution(mode: .native, developerInstructions: "note"))
        XCTAssertEqual(resolve(nil, bundled: false), Resolution(mode: .native, developerInstructions: "note"))
        XCTAssertEqual(resolve(nil, version: old), Resolution(mode: .legacy, developerInstructions: nil))
        XCTAssertEqual(resolve(nil, offered: nil), Resolution(mode: .legacy, developerInstructions: nil))
        // Known modes keep the offered note on any runtime.
        XCTAssertEqual(resolve(.some(.native), bundled: false, version: old), Resolution(mode: .native, developerInstructions: "note"))
        XCTAssertEqual(resolve(.some(.legacy), offered: nil), Resolution(mode: .legacy, developerInstructions: nil))
        // Unknown modes keep #1833's bundled-runtime condition, with a floor instead of a pin.
        XCTAssertEqual(resolve(.some(nil)), Resolution(mode: nil, developerInstructions: "note"))
        XCTAssertEqual(
            resolve(.some(nil), version: Version(major: 0, minor: 171, patch: 0)),
            Resolution(mode: nil, developerInstructions: "note")
        )
        XCTAssertEqual(resolve(.some(nil), bundled: false), Resolution(mode: nil, developerInstructions: nil))
        XCTAssertEqual(resolve(.some(nil), version: old), Resolution(mode: nil, developerInstructions: nil))
    }

    func testNoteCompositionReadsEffectiveConfigAndFallsBackOnFailure() async throws {
        struct ReadFailure: Error {}
        for configured in ["Use tabs.", nil] as [String?] {
            let methods = MethodRecorder()
            let controller = makeController { method, params in
                methods.append(method)
                XCTAssertEqual(params?["includeLayers"] as? Bool, false)
                XCTAssertEqual(params?["cwd"] as? String, NSTemporaryDirectory())
                let value: Any = configured ?? NSNull()
                return ["config": ["developer_instructions": value]]
            }
            let composed = try await controller.test_developerInstructionsPreservingConfigured("note")
            XCTAssertEqual(composed, configured.map { "note\n\n" + $0 } ?? "note")
            XCTAssertEqual(methods.all, ["config/read"])
            let none = try await controller.test_developerInstructionsPreservingConfigured(nil)
            XCTAssertNil(none)
            XCTAssertEqual(methods.all, ["config/read"], "no note means no config read")
        }
        let failing = makeController { _, _ in throw ReadFailure() }
        let fallback = try await failing.test_developerInstructionsPreservingConfigured("note")
        XCTAssertEqual(fallback, "note")
    }

    func testDeveloperInstructionPlanFollowsConversationModeOnResume() {
        func plan(_ eligible: Bool, _ mode: CodexThreadInstructionMode?) -> CodexDeveloperInstructionPlan {
            CodexDeveloperInstructionPlan.resolve(note: "note", eligibleForNativeStart: eligible, conversationMode: mode)
        }
        // New threads depend only on eligibility.
        XCTAssertEqual(plan(true, .legacy).newThread, "note")
        XCTAssertNil(plan(false, .native).newThread)
        // Recorded modes decide resumes regardless of current eligibility.
        XCTAssertEqual(plan(false, .native).resume, "note")
        XCTAssertEqual(plan(true, .native).resume, "note")
        XCTAssertNil(plan(true, .legacy).resume)
        XCTAssertNil(plan(false, .legacy).resume)
        // Unknown modes keep the eligibility-based behavior.
        XCTAssertEqual(plan(true, nil).resume, "note")
        XCTAssertNil(plan(false, nil).resume)
    }

    func testAgentSessionRoundTripsInstructionMode() throws {
        let session = AgentSession(
            id: UUID(),
            name: "Instruction mode",
            savedAt: Date(timeIntervalSinceReferenceDate: 0),
            autoEditEnabled: false,
            codexConversationID: "thread",
            codexInstructionMode: .native
        )
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.codexInstructionMode, .native)
    }

    func testAgentSessionDecodesMissingOrUnknownInstructionModeAsUnknown() throws {
        for mode in [nil, "\"future-mode\"", "42"] {
            let modeField = mode.map { ",\n  \"codexInstructionMode\": \($0)" } ?? ""
            let payload = """
            {
              "id": "00000000-0000-0000-0000-000000000801",
              "serializationVersion": 9,
              "name": "Codex Session",
              "savedAt": 0,
              "items": [],
              "agentKind": "codexExec",
              "autoEditEnabled": true,
              "codexConversationID": "thread"\(modeField)
            }
            """
            let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))
            XCTAssertNil(decoded.codexInstructionMode, mode ?? "missing")
            XCTAssertEqual(decoded.codexConversationID, "thread")
        }
    }

    /// The lightweight header decoder backs session lists and child-retirement scans, so a
    /// malformed mode must not fail it.
    func testSessionStubDecodesInstructionModeLeniently() async throws {
        let service = AgentSessionDataService.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNativeInstructionPolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(name: "Instruction Mode", repoPaths: ["/tmp/repo"], customStoragePath: directory)
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "Instruction mode stub",
            savedAt: Date(timeIntervalSinceReferenceDate: 30),
            agentKind: AgentProviderKind.codexExec.rawValue,
            autoEditEnabled: true,
            codexConversationID: "thread",
            codexInstructionMode: .native
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        XCTAssertEqual(stub.codexInstructionMode, .native)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        json["codexInstructionMode"] = 42
        try JSONSerialization.data(withJSONObject: json).write(to: fileURL)
        let malformed = try await service.loadAgentSessionStub(from: fileURL)
        XCTAssertNil(malformed.codexInstructionMode)
        XCTAssertEqual(malformed.codexConversationID, "thread")
        let retirementRecords = try await service.persistedChildRetirementRecords(workspace: workspace)
        XCTAssertEqual(retirementRecords.map(\.sessionID), [session.id])
    }

    private final class MethodRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []

        func append(_ method: String) {
            lock.withLock { methods.append(method) }
        }

        var all: [String] {
            lock.withLock { methods }
        }
    }

    private func makeController(
        _ respond: @escaping @Sendable (String, [String: Any]?) throws -> [String: Any]
    ) -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(), runID: UUID(), tabID: UUID(), windowID: 1,
            workspacePaths: .uniform(NSTemporaryDirectory()), options: .agentModeDefault(),
            requestExecutor: { method, params, _ in try respond(method, params) }
        )
    }
}
