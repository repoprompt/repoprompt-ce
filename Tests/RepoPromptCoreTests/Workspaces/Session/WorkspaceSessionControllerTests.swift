@testable import RepoPromptCore
import XCTest

final class WorkspaceSessionControllerTests: XCTestCase {
    func testFirstAuthoritativeSnapshotMustBeAppliedBeforeAdmission() async throws {
        let workspace = makeWorkspace()
        let host = RepoPromptCoreHost(persistenceIO: memoryPersistenceIO())
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: WorkspaceSessionLifecycleHarness()
            )
        )
        let registration = try XCTUnwrap(created)

        let beforeHydration = await registration.handle.admit()
        XCTAssertEqual(beforeHydration, .notReady(.created))

        let hydration = await host.hydrateSession(registration.sessionID)
        guard case let .awaitingFirstSnapshotApplication(firstSnapshot) = hydration else {
            return XCTFail("expected first authoritative snapshot, got \(hydration)")
        }
        XCTAssertEqual(firstSnapshot.stateGeneration, 1)
        XCTAssertEqual(firstSnapshot.availability, .awaitingActivation)

        let beforeApplication = await registration.handle.admit()
        XCTAssertEqual(beforeApplication, .notReady(.awaitingActivation))

        let wrongSequence = await host.acknowledgeFirstSnapshotApplied(
            sessionID: registration.sessionID,
            sequence: firstSnapshot.snapshotSequence + 1
        )
        XCTAssertEqual(
            wrongSequence,
            .wrongSnapshot(
                expected: firstSnapshot.snapshotSequence,
                actual: firstSnapshot.snapshotSequence + 1
            )
        )

        let activation = await host.acknowledgeFirstSnapshotApplied(
            sessionID: registration.sessionID,
            sequence: firstSnapshot.snapshotSequence
        )
        guard case let .activated(activationToken) = activation else {
            return XCTFail("expected activation, got \(activation)")
        }
        XCTAssertEqual(activationToken.firstAuthoritativeGeneration, 1)

        guard case let .admitted(admissionToken) = await registration.handle.admit() else {
            return XCTFail("expected admission after exact snapshot acknowledgement")
        }
        XCTAssertEqual(admissionToken.sessionID, registration.sessionID)
        XCTAssertEqual(admissionToken.activationID, activationToken.activationID)
    }

    func testSelectionExpectedRevisionRejectsStaleAndDistinguishesABA() async throws {
        let workspace = makeWorkspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let activeSession = try await makeActiveSession(workspace: workspace)
        let host = activeSession.host
        let registration = activeSession.registration
        let admission = activeSession.admission
        defer { Task { await host.shutdown() } }

        let selectionB = StoredSelection(selectedPaths: ["/tmp/B.swift"])
        let firstCommandID = UUID()
        let first = WorkspaceSessionCommandEnvelope(
            commandID: firstCommandID,
            admissionToken: admission,
            expectedGeneration: 1,
            command: .selection(
                WorkspaceSelectionCommand(
                    workspaceID: workspace.id,
                    tabID: tabID,
                    expectedRevision: 0,
                    selection: selectionB
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case let .committed(firstReceipt) = await registration.handle.execute(first) else {
            return XCTFail("first selection replacement did not commit")
        }
        XCTAssertEqual(firstReceipt.selectionRevision, 1)
        XCTAssertEqual(firstReceipt.resultingGeneration, 2)

        let duplicate = await registration.handle.execute(first)
        XCTAssertEqual(duplicate, .committed(firstReceipt))
        let duplicateSnapshot = await registration.handle.currentSnapshot()
        XCTAssertEqual(duplicateSnapshot?.stateGeneration, 2)

        let stale = WorkspaceSessionCommandEnvelope(
            admissionToken: admission,
            expectedGeneration: 2,
            command: .selection(
                WorkspaceSelectionCommand(
                    workspaceID: workspace.id,
                    tabID: tabID,
                    expectedRevision: 0,
                    selection: StoredSelection(selectedPaths: ["/tmp/stale.swift"])
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case let .stale(staleSnapshot, conflict) = await registration.handle.execute(stale) else {
            return XCTFail("expected stale revision conflict")
        }
        XCTAssertEqual(staleSnapshot.selectionRevision(workspaceID: workspace.id, tabID: tabID), 1)
        XCTAssertEqual(
            conflict.kind,
            .selectionRevision(
                key: WorkspaceTabSelectionKey(workspaceID: workspace.id, tabID: tabID),
                expected: 0,
                actual: 1
            )
        )

        let selectionA = StoredSelection()
        let backToA = WorkspaceSessionCommandEnvelope(
            admissionToken: admission,
            expectedGeneration: 2,
            command: .selection(
                WorkspaceSelectionCommand(
                    workspaceID: workspace.id,
                    tabID: tabID,
                    expectedRevision: 1,
                    selection: selectionA
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case let .committed(abaReceipt) = await registration.handle.execute(backToA) else {
            return XCTFail("ABA replacement did not commit")
        }
        XCTAssertEqual(abaReceipt.selectionRevision, 2)
        let currentABASnapshot = await registration.handle.currentSnapshot()
        let abaSnapshot = try XCTUnwrap(currentABASnapshot)
        XCTAssertEqual(abaSnapshot.selection(workspaceID: workspace.id, tabID: tabID), selectionA)
        XCTAssertEqual(abaSnapshot.selectionRevision(workspaceID: workspace.id, tabID: tabID), 2)
    }

    func testSelectionAndNonSelectionPatchCommitAtomicallyAndPatchCannotReplaceSelection() async throws {
        let workspace = makeWorkspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let activeSession = try await makeActiveSession(workspace: workspace)
        defer { Task { await activeSession.host.shutdown() } }

        var patchedTab = try XCTUnwrap(workspace.composeTabs.first)
        patchedTab.promptText = "atomic prompt"
        patchedTab.name = "Atomic"
        patchedTab.selection = StoredSelection(selectedPaths: ["ignored-by-patch.swift"])
        let selection = StoredSelection(selectedPaths: ["selected.swift"])
        let atomic = WorkspaceSessionCommandEnvelope(
            admissionToken: activeSession.admission,
            expectedGeneration: 1,
            command: .selectionAndPatch(
                WorkspaceSelectionAndTabPatchCommand(
                    selection: WorkspaceSelectionCommand(
                        workspaceID: workspace.id,
                        tabID: tabID,
                        expectedRevision: 0,
                        selection: selection
                    ),
                    patch: ComposeTabNonSelectionPatch(tab: patchedTab)
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case let .committed(receipt) = await activeSession.registration.handle.execute(atomic) else {
            return XCTFail("atomic selection and patch did not commit")
        }
        XCTAssertEqual(receipt.sessionID, activeSession.registration.sessionID)
        XCTAssertEqual(receipt.activationID, activeSession.admission.activationID)
        XCTAssertEqual(receipt.selectionRevision, 1)

        let firstCurrentSnapshot = await activeSession.registration.handle.currentSnapshot()
        var current = try XCTUnwrap(firstCurrentSnapshot)
        var tab = try XCTUnwrap(current.workspaces.first?.composeTabs.first)
        XCTAssertEqual(tab.selection, selection)
        XCTAssertEqual(tab.promptText, "atomic prompt")

        patchedTab.promptText = "patch only"
        patchedTab.selection = StoredSelection(selectedPaths: ["must-not-replace.swift"])
        let patchOnly = WorkspaceSessionCommandEnvelope(
            admissionToken: activeSession.admission,
            expectedGeneration: 2,
            command: .composeTab(
                .patch(
                    workspaceID: workspace.id,
                    tabID: tabID,
                    patch: ComposeTabNonSelectionPatch(tab: patchedTab)
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case .committed = await activeSession.registration.handle.execute(patchOnly) else {
            return XCTFail("non-selection patch did not commit")
        }
        let secondCurrentSnapshot = await activeSession.registration.handle.currentSnapshot()
        current = try XCTUnwrap(secondCurrentSnapshot)
        tab = try XCTUnwrap(current.workspaces.first?.composeTabs.first)
        XCTAssertEqual(tab.selection, selection)
        XCTAssertEqual(tab.promptText, "patch only")
        XCTAssertEqual(current.selectionRevision(workspaceID: workspace.id, tabID: tabID), 1)

        let titleDate = Date(timeIntervalSince1970: 1_234)
        let titleOnly = WorkspaceSessionCommandEnvelope(
            admissionToken: activeSession.admission,
            expectedGeneration: 3,
            command: .composeTab(.patchTitle(
                workspaceID: workspace.id,
                tabID: tabID,
                name: "Title only",
                lastModified: titleDate
            )),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case .committed = await activeSession.registration.handle.execute(titleOnly) else {
            return XCTFail("title-only patch did not commit")
        }
        let currentTitleSnapshot = await activeSession.registration.handle.currentSnapshot()
        let titleSnapshot = try XCTUnwrap(currentTitleSnapshot)
        let titleTab = try XCTUnwrap(titleSnapshot.workspaces.first?.composeTabs.first)
        XCTAssertEqual(titleTab.name, "Title only")
        XCTAssertEqual(titleTab.lastModified, titleDate)
        XCTAssertEqual(titleTab.selection, selection)
        XCTAssertEqual(titleTab.promptText, "patch only")
        XCTAssertEqual(titleSnapshot.selectionRevision(workspaceID: workspace.id, tabID: tabID), 1)
    }

    func testHostAllocatorIsCanonicalAcrossSessions() async throws {
        let host = RepoPromptCoreHost(persistenceIO: memoryPersistenceIO())
        let firstWorkspace = makeWorkspace(name: "First")
        let secondWorkspace = makeWorkspace(name: "Second")
        let first = try await makeActiveSession(host: host, workspace: firstWorkspace)
        let second = try await makeActiveSession(host: host, workspace: secondWorkspace)

        let firstRevision = try await replaceSelection(
            registration: first.registration,
            admission: first.admission,
            workspace: firstWorkspace,
            selectedPath: "/tmp/one"
        )
        let secondRevision = try await replaceSelection(
            registration: second.registration,
            admission: second.admission,
            workspace: secondWorkspace,
            selectedPath: "/tmp/two"
        )

        XCTAssertEqual(firstRevision, 1)
        XCTAssertEqual(secondRevision, 2)
        await host.shutdown()
    }
}

private extension WorkspaceSessionControllerTests {
    struct ActiveSession {
        let host: RepoPromptCoreHost
        let registration: RepoPromptCoreSessionRegistration
        let admission: WorkspaceSessionAdmissionToken
    }

    func makeActiveSession(workspace: WorkspaceModel) async throws -> ActiveSession {
        let host = RepoPromptCoreHost(persistenceIO: memoryPersistenceIO())
        let active = try await makeActiveSession(host: host, workspace: workspace)
        return ActiveSession(host: host, registration: active.registration, admission: active.admission)
    }

    func makeActiveSession(
        host: RepoPromptCoreHost,
        workspace: WorkspaceModel
    ) async throws -> (registration: RepoPromptCoreSessionRegistration, admission: WorkspaceSessionAdmissionToken) {
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: WorkspaceSessionLifecycleHarness()
            )
        )
        let registration = try XCTUnwrap(created)
        guard case let .awaitingFirstSnapshotApplication(snapshot) = await host.hydrateSession(registration.sessionID) else {
            throw TestFailure.unexpectedResult
        }
        guard case .activated = await host.acknowledgeFirstSnapshotApplied(
            sessionID: registration.sessionID,
            sequence: snapshot.snapshotSequence
        ) else {
            throw TestFailure.unexpectedResult
        }
        guard case let .admitted(admission) = await registration.handle.admit() else {
            throw TestFailure.unexpectedResult
        }
        return (registration, admission)
    }

    func replaceSelection(
        registration: RepoPromptCoreSessionRegistration,
        admission: WorkspaceSessionAdmissionToken,
        workspace: WorkspaceModel,
        selectedPath: String
    ) async throws -> UInt64 {
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let command = WorkspaceSessionCommandEnvelope(
            admissionToken: admission,
            expectedGeneration: 1,
            command: .selection(
                WorkspaceSelectionCommand(
                    workspaceID: workspace.id,
                    tabID: tabID,
                    expectedRevision: 0,
                    selection: StoredSelection(selectedPaths: [selectedPath])
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case let .committed(receipt) = await registration.handle.execute(command),
              let revision = receipt.selectionRevision
        else { throw TestFailure.unexpectedResult }
        return revision
    }
}

private enum TestFailure: Error {
    case unexpectedResult
}

private func makeWorkspace(name: String = "Workspace") -> WorkspaceModel {
    WorkspaceModel(name: name, repoPaths: ["/tmp/root"])
}

private func memoryPersistenceIO() -> WorkspaceSessionPersistenceIO {
    WorkspaceSessionPersistenceIO(
        read: { _ in nil },
        atomicWrite: { _, _ in },
        fingerprint: { _ in nil }
    )
}
