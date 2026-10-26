import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderFrozenPackTests: XCTestCase {
    func testCanonicalPackBytesAreStableAndReviewPromptIsAdviserOnly() throws {
        let evidenceGuidance = "Cite each important factual claim with one or more tool-ready `path:start-end` references drawn from the frozen Context Builder evidence. Label each cited claim as a direct observation or an inference. For an inference, identify and cite the supporting observations. Ground important recommendations in those cited claims."
        let reviewGuidance = """
        Review the frozen package independently. Check the task's exact requirements against observed evidence.
        Treat command and test output as stronger evidence than claims of success, and flag unresolved errors or failed verification.
        Report concrete correctness, regression, state-safety, and test gaps with file references. Do not synthesize other Oracle answers.

        \(evidenceGuidance)
        """
        let prompt = ContextBuilderFrozenOraclePack.prompt(for: .review, prompt: "Review this change")
        XCTAssertEqual(prompt, "Review this change\n\n" + reviewGuidance)
        XCTAssertTrue(prompt.contains("path:start-end"))
        XCTAssertTrue(prompt.contains("direct observation"))
        XCTAssertTrue(prompt.contains("inference"))
        XCTAssertTrue(prompt.contains("Ground important recommendations in those cited claims"))
        XCTAssertTrue(prompt.contains("exact requirements against observed evidence"))
        XCTAssertTrue(prompt.contains("command and test output as stronger evidence than claims of success"))
        XCTAssertTrue(prompt.contains("Do not synthesize other Oracle answers"))

        let message = AIMessage(systemPrompt: "system", userMessage: prompt)
        let content = ContextBuilderFrozenOraclePack.render(message)
        let first = try OracleFrozenContextPack(mode: .review, content: content).canonicalData()
        let second = try OracleFrozenContextPack(mode: .review, content: content).canonicalData()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try OracleFrozenContextPack.decodeCanonical(first).content, content)
    }

    func testPlanPromptIncludesEvidenceGuidance() {
        let expected = "Make a plan\n\nCite each important factual claim with one or more tool-ready `path:start-end` references drawn from the frozen Context Builder evidence. Label each cited claim as a direct observation or an inference. For an inference, identify and cite the supporting observations. Ground important recommendations in those cited claims."
        let prompt = ContextBuilderFrozenOraclePack.prompt(for: .plan, prompt: "Make a plan")

        XCTAssertEqual(prompt, expected)
        XCTAssertTrue(prompt.contains("path:start-end"))
        XCTAssertTrue(prompt.contains("direct observation"))
        XCTAssertTrue(prompt.contains("inference"))
        XCTAssertTrue(prompt.contains("Ground important recommendations in those cited claims"))
        XCTAssertFalse(prompt.contains("Review the frozen package independently"))
    }

    func testChatPromptIsUnchanged() {
        XCTAssertEqual(
            ContextBuilderFrozenOraclePack.prompt(for: .chat, prompt: "Answer this question\n"),
            "Answer this question\n"
        )
    }

    @MainActor
    func testFailedInputConstructionReleasesArtifactReservation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderFrozenPackTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: ProcessInfo.processInfo.processIdentifier,
            mode: .app,
            createdAt: Date()
        )
        let persistence = DomainPersistenceCoordinator(
            configuration: DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "frozen-pack-reservation",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events"),
                temporaryDirectory: root.appendingPathComponent("Temporary"),
                externalReloadInterval: nil
            ),
            identity: identity
        )
        let store = DomainOracleConversationStore(persistence: persistence, identity: identity)
        let message = AIMessage(systemPrompt: "system", userMessage: "context")
        let pack = try OracleFrozenContextPack(
            mode: .review,
            content: ContextBuilderFrozenOraclePack.render(message)
        )
        let artifactID = try DomainContentDigest.sha256(pack.canonicalData())

        do {
            _ = try await ContextBuilderFrozenOraclePack.make(
                mode: .review,
                prompt: " \n ",
                selection: StoredSelection(),
                message: message,
                store: store
            )
            XCTFail("Expected whitespace-only Oracle input to be rejected")
        } catch {}

        try await store.removeArtifactIfUnreferenced(id: artifactID)
        do {
            _ = try await store.loadArtifact(id: artifactID)
            XCTFail("Expected failed frozen-pack construction to release and remove its artifact")
        } catch let error as OraclePersistenceError {
            XCTAssertEqual(error, .artifactMissing(artifactID))
        }
    }
}
