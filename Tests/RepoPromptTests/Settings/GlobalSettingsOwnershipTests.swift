import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class GlobalSettingsOwnershipTests: XCTestCase {
    func testTwoStoresRejectStaleSaveAndMigrationThenReloadAllowsFreshEdit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let first = GlobalSettingsFileStore(fileURL: url)
        try first.save(document("original"))
        let second = GlobalSettingsFileStore(fileURL: url)
        let stale = try second.load()
        try first.save(document("other-writer"))
        let winner = try Data(contentsOf: url)

        assertChanged { try second.save(stale) }
        assertChanged {
            try second.saveStartupMigrationPreservingUnknownFields(stale, includeModelSelectionRepair: true)
        }
        XCTAssertEqual(try Data(contentsOf: url), winner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))

        var fresh = try second.load()
        XCTAssertEqual(fresh.globalDefaults.discoverAgentRaw, "other-writer")
        fresh.globalDefaults.discoverAgentRaw = "fresh-edit"
        try second.save(fresh)
        XCTAssertEqual(try first.load().globalDefaults.discoverAgentRaw, "fresh-edit")
    }

    func testFutureReplacementRejectsMigrationRecoveryAndImportWithoutBackup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsFileStore(fileURL: url)
        try store.save(document("original"))
        let stale = try store.load()
        var future = document("future-writer")
        future.schemaVersion = GlobalSettingsDocument.currentSchemaVersion + 1
        let futureBytes = try encoded(future)
        try GlobalSettingsTransactionLock.withLock(for: url) {
            try futureBytes.write(to: url, options: .atomic)
        }

        assertChanged {
            try store.saveStartupMigrationPreservingUnknownFields(stale, includeModelSelectionRepair: true)
        }
        XCTAssertFalse(store.performUserInitiatedRecovery(replacementDocument: stale))
        XCTAssertFalse(store.performUserInitiatedCompatibleImport())
        XCTAssertEqual(try Data(contentsOf: url), futureBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(store.blockReason, .unsupportedFutureSchema(
            onDiskVersion: GlobalSettingsDocument.currentSchemaVersion + 1,
            supportedVersion: GlobalSettingsDocument.currentSchemaVersion
        ))
    }

    func testBusyInitialLoadCannotSaveProvisionalDefaultsAndReloadAdoptsWinner() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let suiteName = "GlobalSettingsOwnershipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileStore = GlobalSettingsFileStore(fileURL: url)
        let winner = try encoded(document("winner"))
        let settings = try GlobalSettingsTransactionLock.withLock(for: url) {
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
            XCTAssertEqual(settings.persistenceBlockReason, .loadFailed)
            // Simulate the cooperative owner finishing creation while this app has
            // provisional in-memory defaults. No startup retry may claim those bytes.
            try winner.write(to: url, options: .atomic)
            return settings
        }
        settings.setAppearanceModeRaw("Dark")
        XCTAssertFalse(settings.retryBlockedPersistenceSave())
        XCTAssertEqual(try Data(contentsOf: url), winner)
        XCTAssertTrue(settings.reloadFromDisk())
        XCTAssertEqual(try fileStore.load().globalDefaults.discoverAgentRaw, "winner")
        settings.setAppearanceModeRaw("Light")
        XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.appearanceMode, "Light")
    }

    func testInitialReadFailureNeverBacksUpOrSavesDefaultsAndFailedReloadRetainsMemory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        // A directory at the document path deterministically produces a read failure,
        // without relying on process privileges or chmod behavior.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let fileStore = GlobalSettingsFileStore(fileURL: url)
        let suiteName = "GlobalSettingsOwnershipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertEqual(settings.persistenceBlockReason, .loadFailed)
        settings.setAppearanceModeRaw("Dark")
        XCTAssertFalse(settings.reloadFromDisk())
        XCTAssertEqual(settings.appearanceModeRaw(), "Dark")
        XCTAssertFalse(settings.retryBlockedPersistenceSave())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))

        try FileManager.default.removeItem(at: url)
        try encoded(document("readable-now")).write(to: url, options: .atomic)
        XCTAssertTrue(settings.reloadFromDisk())
        XCTAssertEqual(try fileStore.load().globalDefaults.discoverAgentRaw, "readable-now")
    }

    func testBusyInitialCreationCanReloadIfOtherOwnerLeavesFileAbsent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsFileStore(fileURL: url)
        let provisional = try GlobalSettingsTransactionLock.withLock(for: url) {
            store.loadOrCreateDefault()
        }
        XCTAssertEqual(store.blockReason, .loadFailed)
        XCTAssertThrowsError(try store.save(provisional))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        _ = try store.load()
        XCTAssertNil(store.blockReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNormalizationHoldsWriterLockAndAdvancesObservedContent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let competitor = GlobalSettingsFileStore(fileURL: url)
        try competitor.save(GlobalSettingsDocument())
        let original = try competitor.load()
        var falseV4 = original
        falseV4.schemaVersion = GlobalSettingsDocument.workspaceAgentModelsSchemaVersion
        try encoded(falseV4).write(to: url, options: .atomic)
        var normalized = false
        let store = GlobalSettingsFileStore(fileURL: url, normalizationAtomicWriter: { bytes, destination in
            XCTAssertThrowsError(try competitor.save(original)) { error in
                XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .writerBusy)
            }
            try bytes.write(to: destination, options: .atomic)
            normalized = true
        })
        let loaded = try store.load()
        XCTAssertTrue(normalized)
        XCTAssertEqual(loaded.schemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        try store.save(loaded)
        XCTAssertNil(store.blockReason)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path)
        XCTAssertEqual(backups.count, 1)
    }

    func testMigrationHoldsLockThroughReplacementThenAllowsReloadedWriter() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let competitor = GlobalSettingsFileStore(fileURL: url)
        var unmigrated = document("original")
        unmigrated.scalarPreferences?.contextBuilder = nil
        try competitor.save(unmigrated)
        let originalBytes = try Data(contentsOf: url)
        var replacementCount = 0
        let store = GlobalSettingsFileStore(fileURL: url, startupMigrationAtomicWriter: { bytes, destination in
            // The migration has already read and merged its raw input. A second
            // cooperative writer must still be excluded at the final replacement.
            XCTAssertThrowsError(try competitor.save(self.document("competing-write"))) { error in
                XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .writerBusy)
            }
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
            try bytes.write(to: destination, options: .atomic)
            replacementCount += 1
        })
        var migration = try store.load()
        migration.scalarPreferences?.contextBuilder = GlobalScalarPreferences.ContextBuilderSettings(
            contextTokenBudget: 5678
        )
        try store.saveStartupMigrationPreservingUnknownFields(migration, includeModelSelectionRepair: false)
        XCTAssertEqual(replacementCount, 1)
        let migratedBytes = try Data(contentsOf: url)
        XCTAssertNotEqual(migratedBytes, originalBytes)
        assertChanged { try competitor.save(document("stale-after-migration")) }
        XCTAssertEqual(try Data(contentsOf: url), migratedBytes)
        let fresh = try competitor.load()
        XCTAssertEqual(fresh.scalarPreferences?.contextBuilder?.contextTokenBudget, 5678)
        try competitor.save(fresh)
        XCTAssertNil(competitor.blockReason)
    }

    func testFailedMigrationRetryRejectsNewGenerationAndReloadRetiresOldIntent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let first = GlobalSettingsFileStore(fileURL: url)
        try first.save(document("original"))
        var attempts = 0
        let store = GlobalSettingsFileStore(fileURL: url, startupMigrationAtomicWriter: { _, _ in
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        })
        let original = try store.load()
        XCTAssertThrowsError(try store.saveStartupMigrationPreservingUnknownFields(
            original, includeModelSelectionRepair: false
        ))
        XCTAssertTrue(store.hasPendingStartupMigration)
        try first.save(document("winner"))
        let winner = try Data(contentsOf: url)
        assertChanged { try store.retryStartupMigrationPreservingUnknownFields(document("stale-retry")) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try Data(contentsOf: url), winner)
        let fresh = try store.load()
        XCTAssertFalse(store.hasPendingStartupMigration)
        XCTAssertEqual(fresh.globalDefaults.discoverAgentRaw, "winner")
        try store.save(fresh)
    }

    func testFailedRecoveryRetainsMissingGenerationAndRejectsAnotherWritersReplacement() throws {
        for competingWriter in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("globalSettings.json")
            var foreign = document("foreign")
            foreign.schemaLineage = "foreign.fixture"
            try encoded(foreign).write(to: url, options: .atomic)
            var shouldFail = true
            let store = GlobalSettingsFileStore(fileURL: url, atomicWriter: { bytes, destination in
                if shouldFail { throw CocoaError(.fileWriteNoPermission) }
                try bytes.write(to: destination, options: .atomic)
            })
            _ = store.loadOrCreateDefault()
            let intended = document("retained-intent")
            XCTAssertFalse(store.performUserInitiatedRecovery(replacementDocument: intended))
            XCTAssertEqual(store.blockReason, .saveFailed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            shouldFail = false
            if competingWriter {
                try GlobalSettingsFileStore(fileURL: url).save(document("replacement"))
                let winner = try Data(contentsOf: url)
                assertChanged { try store.save(intended) }
                XCTAssertEqual(try Data(contentsOf: url), winner)
            } else {
                try store.save(intended)
                XCTAssertEqual(try store.load().globalDefaults.discoverAgentRaw, "retained-intent")
            }
            let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path)
            XCTAssertEqual(backups.count, 1)
        }
    }

    func testMissingFileOffersExplicitRecreationAndRejectsInterveningReplacement() throws {
        for competingWriter in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("globalSettings.json")
            let suiteName = "GlobalSettingsOwnershipTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let fileStore = GlobalSettingsFileStore(fileURL: url)
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
            settings.setAppearanceModeRaw("Dark")
            try FileManager.default.removeItem(at: url)
            settings.setAppearanceModeRaw("Light")
            XCTAssertEqual(settings.persistenceBlockReason, .missingOnDisk)
            XCTAssertFalse(settings.retryBlockedPersistenceSave())
            XCTAssertFalse(settings.reloadFromDisk())
            XCTAssertEqual(settings.persistenceBlockReason, .missingOnDisk)
            XCTAssertEqual(settings.appearanceModeRaw(), "Light")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            if competingWriter {
                try GlobalSettingsFileStore(fileURL: url).save(document("replacement"))
                let winner = try Data(contentsOf: url)
                XCTAssertFalse(settings.recoverBlockedPersistenceAfterBackup())
                XCTAssertEqual(settings.persistenceBlockReason, .changedOnDisk)
                XCTAssertEqual(try Data(contentsOf: url), winner)
            } else {
                XCTAssertTrue(settings.recoverBlockedPersistenceAfterBackup())
                XCTAssertEqual(try fileStore.load().scalarPreferences?.ui?.appearanceMode, "Light")
            }
        }
    }

    func testFailedFirstCreationCanExplicitlyPersistRetainedValues() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        var shouldFail = true
        let fileStore = GlobalSettingsFileStore(fileURL: url, atomicWriter: { bytes, destination in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try bytes.write(to: destination, options: .atomic)
        })
        _ = fileStore.loadOrCreateDefault()
        XCTAssertEqual(fileStore.blockReason, .saveFailed)
        XCTAssertThrowsError(try fileStore.load())
        XCTAssertEqual(fileStore.blockReason, .missingOnDisk)
        shouldFail = false
        XCTAssertTrue(fileStore.performUserInitiatedRecovery(replacementDocument: document("retained")))
        XCTAssertEqual(try fileStore.load().globalDefaults.discoverAgentRaw, "retained")
    }

    func testFailedCompatibleImportPreservesPrimaryAndRetriesImportInsteadOfDefaults() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        var foreign = document("imported-intent")
        foreign.schemaLineage = "foreign.fixture"
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(foreign)) as? [String: Any])
        raw["foreignOnly"] = "preserved-in-backup"
        let original = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try original.write(to: url)
        var shouldFail = true
        let fileStore = GlobalSettingsFileStore(fileURL: url, atomicWriter: { bytes, destination in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try bytes.write(to: destination, options: .atomic)
        })
        let suiteName = "GlobalSettingsOwnershipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertFalse(settings.importBlockedPersistenceAfterBackup())
        XCTAssertEqual(settings.persistenceBlockReason, .incompatibleSchema)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(settings.retryBlockedPersistenceSave())
        XCTAssertEqual(try Data(contentsOf: url), original)
        shouldFail = false
        XCTAssertTrue(settings.importBlockedPersistenceAfterBackup())
        XCTAssertEqual(try fileStore.load().globalDefaults.discoverAgentRaw, "imported-intent")
        let backupURLs = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backupURLs.count, 2)
        for backup in backupURLs {
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    func testProcessContentionReturnsBusyThenDetectsCommittedGeneration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsFileStore(fileURL: url)
        try store.save(document("original"))
        let payload = root.appendingPathComponent("payload.json")
        try encoded(document("child-writer")).write(to: payload)
        let child = try SettingsLockProcess(settingsURL: url, payloadURL: payload)
        defer { child.stop() }
        try child.waitUntilLocked()
        XCTAssertThrowsError(try store.save(document("parent-edit"))) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .writerBusy)
        }
        XCTAssertEqual(store.blockReason, .writerBusy)
        try child.finish(command: "w")
        assertChanged { try store.save(document("stale-parent-edit")) }
        XCTAssertEqual(try store.load().globalDefaults.discoverAgentRaw, "child-writer")
    }

    func testProcessCrashReleasesLockWithoutRemovingSidecar() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsFileStore(fileURL: url)
        try store.save(document("original"))
        let child = try SettingsLockProcess(settingsURL: url, payloadURL: url)
        defer { child.stop() }
        try child.waitUntilLocked()
        XCTAssertThrowsError(try store.save(document("blocked")))
        try child.finish(command: "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: GlobalSettingsTransactionLock.lockURL(for: url).path))
        try store.save(document("after-crash"))
        XCTAssertEqual(try store.load().globalDefaults.discoverAgentRaw, "after-crash")
    }

    private func assertChanged(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError,
                .settingsChangedOnDisk, file: file, line: line
            )
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsOwnership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func document(_ marker: String) -> GlobalSettingsDocument {
        GlobalSettingsDocument(
            globalDefaults: GlobalDefaults(discoverAgentRaw: marker, discoverModelsByAgent: nil),
            scalarPreferences: GlobalScalarPreferences(
                contextBuilder: GlobalScalarPreferences.ContextBuilderSettings(contextTokenBudget: 4321),
                fileSystem: GlobalScalarPreferences.FileSystemSettings(globalIgnoreDefaults: "")
            )
        )
    }

    private func encoded(_ document: GlobalSettingsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
}

/// A separate cooperative writer with pipe barriers. All waits are bounded; the child
/// is killed on every unfinished exit. No PID file or timing sleep participates in proof.
private final class SettingsLockProcess {
    private enum FixtureError: Error {
        case timeout(String)
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let ready = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)

    init(settingsURL: URL, payloadURL: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, os, select, sys
        target, sidecar, payload = sys.argv[1:]
        fd = os.open(sidecar, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.stdout.buffer.write(b'L'); sys.stdout.buffer.flush()
        # Fixture watchdog only: ownership/order proof uses pipe barriers, not elapsed time.
        if not select.select([sys.stdin.buffer], [], [], 10)[0]: os._exit(18)
        command = sys.stdin.buffer.read(1)
        if command == b'x': os._exit(17)
        if command == b'w': os.replace(payload, target)
        os.close(fd)
        """, settingsURL.path, GlobalSettingsTransactionLock.lockURL(for: settingsURL).path, payloadURL.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ready = ready
        output.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.contains(UInt8(ascii: "L")) { ready.signal() }
            handle.readabilityHandler = nil
        }
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
    }

    func waitUntilLocked() throws {
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw FixtureError.timeout("child lock acquisition")
        }
    }

    func finish(command: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data(command.utf8))
        guard exited.wait(timeout: .now() + 5) == .success else {
            throw FixtureError.timeout("child exit")
        }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
}
