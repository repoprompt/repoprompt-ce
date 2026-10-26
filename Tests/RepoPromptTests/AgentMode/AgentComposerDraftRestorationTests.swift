import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import UniformTypeIdentifiers
import XCTest

@MainActor
final class AgentComposerDraftRestorationTests: XCTestCase {
    func testCoalescedManualAndQueuedRecoveriesRestoreEachFragmentOnce() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        viewModel.storeDraftText(for: tabID, "D")

        viewModel.restoreRejectedManualSubmissionComposerState(
            tabID: tabID,
            session: session,
            draftText: "B",
            attachments: [],
            taggedFiles: [],
            selectedWorkflow: nil,
            selectedWorkflowMutationGeneration: nil,
            message: "Failed start"
        )
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )

        let finalEvent = try XCTUnwrap(viewModel.draftRestorationEvent)
        let operation = try XCTUnwrap(finalEvent.operation)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "C\nB\nD")
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                operation,
                to: "D",
                acknowledgedSequence: 0
            ),
            "C\nB\nD"
        )
    }

    func testConsumedRecoveryAndNewerTypingAreNotDuplicated() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "B",
            message: "Failed start",
            strategy: .prependAlways
        )
        let firstOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            acknowledgedSequence: 0
        )
        XCTAssertEqual(firstEditorText, "B\nD")

        let editedText = firstEditorText + "\nnew typing"
        viewModel.storeDraftText(
            for: tabID,
            editedText,
            acknowledgingThrough: firstOperation.fragments.last?.sequence ?? 0
        )
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )
        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: editedText,
                acknowledgedSequence: firstOperation.fragments.last?.sequence ?? 0
            ),
            "C\nB\nD\nnew typing"
        )
    }

    func testSkippedIntermediateRecoveryStillAppliesOnlyMissingFragments() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        let firstOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            acknowledgedSequence: 0
        )
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "C", message: "", strategy: .prependAlways)

        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: firstEditorText,
                acknowledgedSequence: firstOperation.fragments.last?.sequence ?? 0
            ),
            "C\nB\nA\nD"
        )
    }

    func testInterleavedTabsRetainEachTabsUnconsumedFragments() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let otherTabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")

        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: otherTabID, text: "X", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)

        let operation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(operation.fragments.map(\.text), ["A", "B"])
        let editorText = AgentComposerDraftRestorationReducer.apply(
            operation,
            to: "D",
            acknowledgedSequence: 0
        )
        XCTAssertEqual(editorText, "B\nA\nD")
        viewModel.storeDraftText(
            for: tabID,
            editorText,
            acknowledgingThrough: operation.fragments.last?.sequence ?? 0
        )
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "B\nA\nD")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
        XCTAssertEqual(viewModel.draftRestorationLedger.tabs[otherTabID]?.pendingFragments.map(\.text), ["X"])
    }

    func testStaleEditorStorePreservesRecoveryPendingAtTabSwitch() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)

        // The old editor value is stored as the tab changes before it sees A.
        viewModel.storeDraftText(for: tabID, "D", acknowledgingThrough: 0)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "A\nD")
        let snapshot = viewModel.loadDraftSnapshotForComposer(for: tabID)
        XCTAssertEqual(snapshot.text, "A\nD")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
    }

    func testLoadedSnapshotAndDeletionDoNotResurrectAcknowledgedRecovery() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        let oldOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let snapshot = viewModel.loadDraftSnapshotForComposer(for: tabID)
        XCTAssertEqual(snapshot.text, "A")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)

        viewModel.storeDraftText(for: tabID, "", acknowledgingThrough: snapshot.restorationSequence)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                oldOperation,
                to: "",
                acknowledgedSequence: snapshot.restorationSequence
            ),
            ""
        )
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "C", message: "", strategy: .prependAlways)

        let operation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(operation.fragments.map(\.text), ["B", "C"])
        let editorText = AgentComposerDraftRestorationReducer.apply(
            operation,
            to: "",
            acknowledgedSequence: snapshot.restorationSequence
        )
        XCTAssertEqual(editorText, "C\nB")
        viewModel.storeDraftText(
            for: tabID,
            editorText,
            acknowledgingThrough: operation.fragments.last?.sequence ?? 0
        )
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "C\nB")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Draft restoration tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "draft restoration test")
            }
        )
    }
}

final class AgentFileAttachmentLegacyDecodingTests: XCTestCase {
    func testLegacyAgentAttachmentDecodesAsAnImageWithItsTitleAsTheName() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","source":{"localFile":{"path":"/tmp/x.png"}},"title":"shot.png","createdAt":0}
        """
        let decoded = try JSONDecoder().decode(AgentFileAttachment.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .image)
        XCTAssertEqual(decoded.facts.fileName, "shot.png")
        XCTAssertEqual(decoded.byteCount, 0)
    }
}

@MainActor
final class AgentAttachmentIntakeTests: XCTestCase {
    private var root: URL!
    private var workspaceDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentAttachmentIntakeTests-\(UUID().uuidString)", isDirectory: true)
        workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.appendingPathComponent("big.bin").path
        )
        try? FileManager.default.removeItem(at: root)
    }

    func testOversizeFileIsRefusedFromItsSizeAloneBeforeAnythingIsReadOrCopied() async throws {
        let limit = OracleAttachmentLimits.production.maxBytesPerFile
        let big = root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(limit + 1))
        try handle.close()
        // Unreadable: any attempt to hash, probe or copy would fail differently than the size refusal.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: big.path)

        let viewModel = makeViewModel()
        let tabID = UUID()
        await viewModel.attachFiles(tabID: tabID, urls: [big]).value

        let session = viewModel.session(for: tabID)
        XCTAssertTrue(session.pendingFileAttachments.isEmpty)
        let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: storageRoot.path)) ?? [], [])
        let refusal = try XCTUnwrap(session.items.last { $0.kind == .error }?.text)
        XCTAssertTrue(refusal.contains("big.bin"), refusal)
        XCTAssertTrue(refusal.contains("the file is 20.1 MiB, over the 20.0 MiB attachment limit"), refusal)
    }

    func testStoreAdmitsFromDirectoryEntryAndRefusesOversizeBeforeCopy() throws {
        let limits = OracleAttachmentLimits(
            maxCount: 10,
            maxBytesPerFile: 4,
            maxTotalBytes: 100,
            maxTitleLength: 100,
            maxInlineTextBytes: 4
        )
        let store = AgentAttachmentStore(limits: limits)
        let small = root.appendingPathComponent("small.txt")
        let large = root.appendingPathComponent("large.txt")
        try Data("abcd".utf8).write(to: small)
        try Data("abcde".utf8).write(to: large)

        XCTAssertEqual(try store.admit(sourceURL: small).byteCount, 4)
        XCTAssertThrowsError(try store.admit(sourceURL: large)) { error in
            XCTAssertEqual(error as? AgentAttachmentStore.Error, .tooLarge(byteCount: 5, limit: 4))
        }
        XCTAssertThrowsError(try store.importFile(sourceURL: large, workspaceDirectory: workspaceDirectory))
        let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
    }

    func testDifferentFilesWithIdenticalBytesBothAttach() async throws {
        let dev = root.appendingPathComponent("config.dev.json")
        let prod = root.appendingPathComponent("config.prod.json")
        try Data("{}".utf8).write(to: dev)
        try Data("{}".utf8).write(to: prod)

        let viewModel = makeViewModel()
        let tabID = UUID()
        await viewModel.attachFiles(tabID: tabID, urls: [dev, prod]).value

        let names = viewModel.session(for: tabID).pendingFileAttachments.map(\.fileName)
        XCTAssertEqual(names, ["config.dev.json", "config.prod.json"])
    }

    func testReattachingTheSameFileSaysSoInsteadOfVanishing() async throws {
        let file = root.appendingPathComponent("table.csv")
        try Data("a,b\n1,2\n".utf8).write(to: file)

        let viewModel = makeViewModel()
        let tabID = UUID()
        await viewModel.attachFiles(tabID: tabID, urls: [file]).value
        await viewModel.attachFiles(tabID: tabID, urls: [file]).value

        XCTAssertEqual(viewModel.session(for: tabID).pendingFileAttachments.map(\.fileName), ["table.csv"])
        let notices = viewModel.session(for: tabID).items.filter { $0.kind == .error }.map(\.text)
        XCTAssertEqual(notices, ["Failed to attach table.csv: it is already attached."])
    }

    func testDelayedIntakeRechecksComposerAdmissionBeforePublishingAndCleansRejectedCopies() async throws {
        for change in ["unchanged", "reprompt", "cleared selection", "different selection", "replaced session", "rebound session", "cycled binding"] {
            let file = root.appendingPathComponent("delayed.txt")
            let data = Data("attachment content".utf8)
            try data.write(to: file)
            let viewModel = makeViewModel()
            let tabID = UUID()
            let session = viewModel.session(for: tabID)
            let store = AgentRepromptUIStore()
            let gate = AttachmentIntakePublicationGate()
            gate.selectedTabID = tabID
            let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
            let filesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: storageRoot.path)) ?? [])
            AgentModeViewModel.attachmentIntakeDidImportForTesting = { importedTabID in
                guard importedTabID == tabID else { return }
                await gate.wait()
            }
            let task = viewModel.attachFiles(tabID: tabID, urls: [file, root], admission: {
                store.allowsAttachmentMutation(tabID: tabID, currentTabID: gate.selectedTabID)
            })
            addTeardownBlock { @MainActor in
                gate.release()
                await task.value
                AgentModeViewModel.attachmentIntakeDidImportForTesting = nil
            }
            try await AsyncTestWait.waitUntil("attachment copied before \(change)", timeout: 3) { gate.entered }
            let filesAfterCopy = try Set(FileManager.default.contentsOfDirectory(atPath: storageRoot.path))
            let importedCopies = filesAfterCopy.subtracting(filesBefore)
            XCTAssertEqual(importedCopies.count, 1, change)
            XCTAssertTrue(session.pendingFileAttachments.isEmpty, change)
            XCTAssertTrue(session.items.isEmpty, change)

            switch change {
            case "reprompt":
                store.presentation = .init(id: UUID(), sourceTabID: tabID, original: "Draft", modelName: "Model")
                store.presentation?.phase = .generating
            case "cleared selection": gate.selectedTabID = nil
            case "different selection": gate.selectedTabID = UUID()
            case "replaced session":
                viewModel.test_removeSession(tabID: tabID)
                _ = viewModel.session(for: tabID)
            case "rebound session": session.testInstallPersistentSessionBinding(sessionID: UUID())
            case "cycled binding": session.testInstallPersistentSessionBinding(sessionID: nil)
            default: break
            }
            gate.release()
            await task.value
            AgentModeViewModel.attachmentIntakeDidImportForTesting = nil

            let admitted = change == "unchanged"
            XCTAssertEqual(session.pendingFileAttachments.map(\.fileName), admitted ? ["delayed.txt"] : [], change)
            XCTAssertEqual(
                session.items.filter { $0.kind == .error }.map(\.text),
                admitted ? ["Failed to attach \(root.lastPathComponent): Only files can be attached, not folders."] : [],
                change
            )
            XCTAssertEqual(
                try Set(FileManager.default.contentsOfDirectory(atPath: storageRoot.path)),
                admitted ? filesAfterCopy : filesBefore,
                change
            )
            XCTAssertEqual(try Data(contentsOf: file), data, "\(change): the original source belongs to the user")
            if change == "replaced session" {
                XCTAssertTrue(viewModel.session(for: tabID).pendingFileAttachments.isEmpty)
                XCTAssertTrue(viewModel.session(for: tabID).items.isEmpty)
            }
        }
    }

    func testDroppedFolderIsRefusedWithAReadableReason() async throws {
        let folder = root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let provider = NSItemProvider(item: folder as NSURL, typeIdentifier: UTType.fileURL.identifier)

        let intake = AgentAttachmentIntake(temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true))
        let result = await withCheckedContinuation { continuation in
            let accepted = intake.loadPreparedAttachments(from: [provider]) { prepared, failures in
                continuation.resume(returning: (prepared, failures))
            }
            XCTAssertTrue(accepted)
        }

        XCTAssertTrue(result.0.isEmpty)
        XCTAssertEqual(
            result.1,
            [AgentAttachmentFailure(fileName: "Reports", reason: "Only files can be attached, not folders.")]
        )

        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.reportAttachmentFailures(tabID: tabID, result.1)
        let message = try XCTUnwrap(viewModel.session(for: tabID).items.last { $0.kind == .error }?.text)
        XCTAssertEqual(message, "Failed to attach Reports: Only files can be attached, not folders.")
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspaceDirectory: workspaceDirectory,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Attachment intake tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "attachment intake test")
            }
        )
    }
}

@MainActor
private final class AttachmentIntakePublicationGate {
    var selectedTabID: UUID?
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
