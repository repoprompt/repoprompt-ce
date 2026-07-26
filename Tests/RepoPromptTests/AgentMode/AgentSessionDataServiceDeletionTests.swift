import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionDataServiceDeletionTests: XCTestCase {
    func testDeleteDrainsInFlightSaveAndPreventsFileResurrection() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storageURL = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Delete Race",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            itemCount: 0,
            autoEditEnabled: true
        )
        let fileURL = storageURL
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
            .standardizedFileURL
        let writeGate = SessionWriteGate()
        await service.test_setBeforeSessionWriteHook { _ in
            await writeGate.blockWrite()
        }

        let saveTask = Task {
            try await service.saveAgentSession(
                session,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
        }
        await writeGate.waitUntilBlocked()

        let deleteTask = Task {
            try await service.deleteAgentSession(id: sessionID, for: workspace)
        }
        await service.test_waitUntilDeletionTombstone(for: fileURL)
        await writeGate.releaseWrite()

        do {
            _ = try await saveTask.value
            XCTFail("Expected the in-flight save to be discarded after deletion was fenced")
        } catch let AgentSessionDataError.sessionDeleted(deletedID) {
            XCTAssertEqual(deletedID, sessionID)
        } catch {
            XCTFail("Unexpected save error: \(error)")
        }
        try await deleteTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let restored = try await service.loadAgentSession(id: sessionID, for: workspace)
        XCTAssertNil(restored)
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionDataServiceDeletionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Agent Session Deletion",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}

private actor SessionWriteGate {
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func blockWrite() async {
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseWrite() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
