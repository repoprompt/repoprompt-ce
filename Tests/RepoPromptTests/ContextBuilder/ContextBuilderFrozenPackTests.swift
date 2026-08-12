import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderFrozenPackTests: XCTestCase {
    func testCanonicalPackBytesAreStableAndReviewPromptIsAdviserOnly() throws {
        let prompt = ContextBuilderFrozenOraclePack.prompt(for: .review, prompt: "Review this change")
        XCTAssertTrue(prompt.contains("Review this change"))
        XCTAssertTrue(prompt.contains("Review the frozen package independently"))
        XCTAssertTrue(prompt.contains("Do not synthesize other Oracle answers"))

        let message = AIMessage(systemPrompt: "system", userMessage: prompt)
        let content = ContextBuilderFrozenOraclePack.render(message)
        let first = try OracleFrozenContextPack(mode: .review, content: content).canonicalData()
        let second = try OracleFrozenContextPack(mode: .review, content: content).canonicalData()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try OracleFrozenContextPack.decodeCanonical(first).content, content)
    }

    func testNonReviewPromptIsUnchanged() {
        XCTAssertEqual(
            ContextBuilderFrozenOraclePack.prompt(for: .plan, prompt: "Make a plan"),
            "Make a plan"
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
