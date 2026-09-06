import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class GlobalSettingsRecoveryTests: XCTestCase {
    func testFailedBackupRecoveryRetainsIntentAndRetryPersistsIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalSettingsRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Settings", isDirectory: true)
            .appendingPathComponent("globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked-settings-fixture".utf8).write(to: fileURL, options: .atomic)

        let suiteName = "GlobalSettingsRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspaceID = UUID()
        let intendedDocument = GlobalSettingsDocument(
            copySettings: [
                workspaceID: CopyGlobalSettings(
                    workspaceID: workspaceID,
                    fileTreeOption: .files,
                    codeMapUsage: .complete,
                    gitInclusion: .all
                )
            ],
            globalDefaults: GlobalDefaults(
                discoverAgentRaw: "fixture-agent",
                discoverModelsByAgent: ["fixture-agent": "fixture-model"],
                didUserSetDiscoverAgentDefaults: true
            ),
            scalarPreferences: GlobalScalarPreferences(
                contextBuilder: GlobalScalarPreferences.ContextBuilderSettings(contextTokenBudget: 4321),
                fileSystem: GlobalScalarPreferences.FileSystemSettings(globalIgnoreDefaults: "")
            )
        )
        let fileStore = FailingRecoveryGlobalSettingsFileStore(
            fileURL: fileURL,
            initialDocument: intendedDocument,
            defaultDocument: GlobalSettingsDocument()
        )
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        XCTAssertEqual(store.persistenceBlockReason, .saveFailed)
        let inMemoryBeforeRecovery = store.copySettings(for: workspaceID)
        XCTAssertEqual(inMemoryBeforeRecovery.fileTreeOption.rawValue, FileTreeOption.files.rawValue)
        XCTAssertEqual(inMemoryBeforeRecovery.codeMapUsage.rawValue, CodeMapUsage.complete.rawValue)
        XCTAssertEqual(inMemoryBeforeRecovery.gitInclusion.rawValue, GitDiffInclusionMode.all.rawValue)

        XCTAssertFalse(store.recoverBlockedPersistenceAfterBackup())
        XCTAssertTrue(fileStore.backupWasCreated)
        XCTAssertTrue(fileStore.replacementWriteFailed)
        XCTAssertEqual(fileStore.recoveryDocuments.count, 1)
        try assertDocument(
            XCTUnwrap(fileStore.recoveryDocuments.last),
            preserves: intendedDocument,
            workspaceID: workspaceID
        )
        XCTAssertTrue(fileStore.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        XCTAssertEqual(fileStore.loadOrCreateDefaultCallCount, 0)
        XCTAssertEqual(store.persistenceBlockReason, .saveFailed)
        XCTAssertEqual(store.copySettings(for: workspaceID).fileTreeOption.rawValue, FileTreeOption.files.rawValue)
        XCTAssertEqual(store.copySettings(for: workspaceID).codeMapUsage.rawValue, CodeMapUsage.complete.rawValue)
        XCTAssertEqual(store.copySettings(for: workspaceID).gitInclusion.rawValue, GitDiffInclusionMode.all.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        XCTAssertTrue(store.retryBlockedPersistenceSave())
        XCTAssertEqual(fileStore.saveDocuments.count, 1)
        let retriedDocument = try XCTUnwrap(fileStore.saveDocuments.last)
        assertDocument(retriedDocument, preserves: intendedDocument, workspaceID: workspaceID)
        XCTAssertNil(store.persistenceBlockReason)
        XCTAssertEqual(fileStore.loadOrCreateDefaultCallCount, 0)
        XCTAssertTrue(fileStore.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func assertDocument(
        _ actual: GlobalSettingsDocument,
        preserves expected: GlobalSettingsDocument,
        workspaceID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.copySettings[workspaceID]?.workspaceID, expected.copySettings[workspaceID]?.workspaceID, file: file, line: line)
        XCTAssertEqual(
            actual.copySettings[workspaceID]?.fileTreeOption.rawValue,
            expected.copySettings[workspaceID]?.fileTreeOption.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.copySettings[workspaceID]?.codeMapUsage.rawValue,
            expected.copySettings[workspaceID]?.codeMapUsage.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.copySettings[workspaceID]?.gitInclusion.rawValue,
            expected.copySettings[workspaceID]?.gitInclusion.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.chatSettings, expected.chatSettings, file: file, line: line)
        XCTAssertEqual(actual.agentModelsSettings, expected.agentModelsSettings, file: file, line: line)
        XCTAssertEqual(actual.globalDefaults, expected.globalDefaults, file: file, line: line)
        XCTAssertEqual(actual.scalarPreferences, expected.scalarPreferences, file: file, line: line)
    }
}

private final class FailingRecoveryGlobalSettingsFileStore: GlobalSettingsFileStoring {
    let fileURL: URL
    private let initialDocument: GlobalSettingsDocument
    private let defaultDocument: GlobalSettingsDocument

    private(set) var blockReason: GlobalSettingsPersistenceBlockReason? = .saveFailed
    private(set) var backupWasCreated = false
    private(set) var replacementWriteFailed = false
    private(set) var backupURL: URL?
    private(set) var loadOrCreateDefaultCallCount = 0
    private(set) var recoveryDocuments: [GlobalSettingsDocument] = []
    private(set) var saveDocuments: [GlobalSettingsDocument] = []

    init(fileURL: URL, initialDocument: GlobalSettingsDocument, defaultDocument: GlobalSettingsDocument) {
        self.fileURL = fileURL
        self.initialDocument = initialDocument
        self.defaultDocument = defaultDocument
    }

    func load() throws -> GlobalSettingsDocument {
        initialDocument
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        loadOrCreateDefaultCallCount += 1
        try? Data("defaults-installed-by-reload".utf8).write(to: fileURL, options: .atomic)
        blockReason = nil
        return defaultDocument
    }

    func save(_ document: GlobalSettingsDocument) throws {
        saveDocuments.append(document)
        do {
            try Data("retried-settings".utf8).write(to: fileURL, options: .atomic)
            blockReason = nil
        } catch {
            blockReason = .saveFailed
            throw error
        }
    }

    func saveStartupMigrationPreservingUnknownFields(
        _ document: GlobalSettingsDocument,
        includeModelSelectionRepair: Bool
    ) throws {}

    var hasPendingStartupMigration: Bool {
        false
    }

    func retryStartupMigrationPreservingUnknownFields(_: GlobalSettingsDocument) throws {
        throw GlobalSettingsFileStore.GlobalSettingsFileStoreError.startupMigrationRetryUnavailable
    }

    func performUserInitiatedRecovery(replacementDocument: GlobalSettingsDocument) -> Bool {
        recoveryDocuments.append(replacementDocument)
        let backupDirectory = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        let candidateBackupURL = backupDirectory.appendingPathComponent("globalSettings.superseded.json")
        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fileURL, to: candidateBackupURL)
            backupURL = candidateBackupURL
            backupWasCreated = true
        } catch {
            blockReason = .saveFailed
            return false
        }

        replacementWriteFailed = true
        blockReason = .saveFailed
        return false
    }

    func performUserInitiatedCompatibleImport() -> Bool {
        false
    }
}
