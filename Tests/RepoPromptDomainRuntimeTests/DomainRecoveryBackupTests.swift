import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// #335 follow-up: durable bytes that need a recovery copy are never replaced (working journal or
/// canonical document) until a verified backup exists. Every test asserts the journal, saved, and
/// backup bytes together with the caller-visible outcome.
final class DomainRecoveryBackupTests: XCTestCase {
    // MARK: - Enforcement sites

    func testWorkingCommitOverUnreadableWorkingCopyIsRefusedUntilBackupSucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let clean = try fixture.document(tabs: ["A", "B"])
        let result1 = await authority.execute(fixture.command(.createWorkspace(clean)))
        XCTAssertEqual(result1.disposition, .applied)
        let unreadable = try fixture.document(tabs: ["A", "B", Fixture.unreadableTab])
        let result2 = await authority.execute(fixture.command(.replaceWorkingDocument(unreadable)))
        XCTAssertEqual(result2.disposition, .applied)

        let reduced = try fixture.document(tabs: ["A", "B"], name: "Reduced")
        let refused = await authority.execute(fixture.command(.replaceWorkingDocument(reduced)))
        XCTAssertEqual(refused.errorCode, .recoveryBackupRequired)
        XCTAssertNil(fixture.verifiedBackup(of: unreadable))
        // Restart-safe: a fresh authority still restores the unreadable working copy.
        let restarted = await fixture.authority().readySnapshot()
        XCTAssertEqual(restarted.workspaces.first?.document.contentDigest, unreadable.contentDigest)
        XCTAssertEqual(try Data(contentsOf: clean.fileURL), clean.documentBytes)

        fixture.probe.setFailing(false)
        let retried = await fixture.authority().execute(fixture.command(.replaceWorkingDocument(reduced)))
        XCTAssertNotEqual(retried.errorCode, .recoveryBackupRequired)
        XCTAssertEqual(fixture.verifiedBackup(of: unreadable).flatMap { try? Data(contentsOf: $0) }, unreadable.documentBytes)
    }

    func testUpgradeStateSaveProtectsUnreadableSavedOriginalUnderReducedJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The canonical document is unreadable for the app; a pre-fix build already journaled a
        // reduced working copy without any backup.
        let original = try fixture.document(tabs: ["A", Fixture.unreadableTab])
        let result3 = await fixture.authority().execute(fixture.command(.createWorkspace(original)))
        XCTAssertEqual(result3.disposition, .applied)
        let reduced = try fixture.document(tabs: ["A"], name: "Reduced")
        let result4 = await fixture.authority().execute(fixture.command(.replaceWorkingDocument(reduced)))
        XCTAssertEqual(result4.disposition, .applied)

        for _ in 0 ..< 2 {
            // Each attempt is refused, including after a restart (the obligation is stateless).
            let save = await fixture.authority().execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
            XCTAssertEqual(save.errorCode, .recoveryBackupRequired)
            XCTAssertEqual(try Data(contentsOf: original.fileURL), original.documentBytes)
            let result5 = await fixture.authority().readySnapshot()
            XCTAssertEqual(result5.workspaces.first?.document.contentDigest, reduced.contentDigest)
        }

        fixture.probe.setFailing(false)
        let saved = await fixture.authority().execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(saved.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: original.fileURL), reduced.documentBytes)
        XCTAssertEqual(fixture.verifiedBackup(of: original).flatMap { try? Data(contentsOf: $0) }, original.documentBytes)
    }

    func testDirtyUnreadableWorkingCopySurvivesExternalChangeReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let result6 = await authority.execute(fixture.command(.createWorkspace(try fixture.document(tabs: ["A"]))))
        XCTAssertEqual(result6.disposition, .applied)
        let unreadable = try fixture.document(tabs: ["A", Fixture.unreadableTab])
        let result7 = await authority.execute(fixture.command(.replaceWorkingDocument(unreadable)))
        XCTAssertEqual(result7.disposition, .applied)

        let external = try fixture.document(tabs: ["A"], name: "External")
        try external.documentBytes.write(to: external.fileURL, options: .atomic)
        _ = await authority.reloadExternalChanges()

        // Whichever path the reload takes (rebase or clean reload), the unreadable working copy is
        // either kept durably or was preserved before being discarded.
        let restored = await fixture.authority().readySnapshot().workspaces.first?.document.contentDigest
        XCTAssertTrue(
            restored == unreadable.contentDigest || fixture.verifiedBackup(of: unreadable) != nil,
            "The unreadable working copy must stay recoverable"
        )
        for replacement in fixture.probe.replacements where replacement.discardedBytes == unreadable.documentBytes {
            XCTAssertEqual(replacement.location, .workingDocument)
        }
    }

    func testMissingCanonicalDocumentStillProtectsJournalBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.probe.setFailing(false)
        let authority = fixture.authority()
        let result8 = await authority.execute(fixture.command(.createWorkspace(try fixture.document(tabs: ["A"]))))
        XCTAssertEqual(result8.disposition, .applied)
        let unreadable = try fixture.document(tabs: ["A", Fixture.unreadableTab])
        let result9 = await authority.execute(fixture.command(.replaceWorkingDocument(unreadable)))
        XCTAssertEqual(result9.disposition, .applied)
        try FileManager.default.removeItem(at: unreadable.fileURL)

        let reduced = try fixture.document(tabs: ["A"], name: "Reduced")
        let outcome = await authority.execute(fixture.command(.replaceWorkingDocument(reduced)))
        // Either the replacement is refused for another reason (nothing discarded), or it applied
        // and the journal bytes were preserved first even though workspace.json is missing.
        if outcome.disposition == .applied {
            XCTAssertEqual(
                fixture.verifiedBackup(of: unreadable).flatMap { try? Data(contentsOf: $0) },
                unreadable.documentBytes,
                "A missing workspace.json must not skip preservation of journal bytes"
            )
        } else {
            XCTAssertNotEqual(outcome.errorCode, .recoveryBackupRequired, "Preservation itself must not need the canonical file")
        }
    }

    func testPreserveCreatesMissingWorkspaceDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let documentURL = fixture.workspaceDirectory.appendingPathComponent("workspace.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceDirectory.path))
        let bytes = Data("journal bytes".utf8)
        let url = try DomainRecoveryBackup.preserve(documentBytes: bytes, documentURL: documentURL)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentURL.path))
    }

    func testGuardIsNotConsultedWhenNothingDurableIsDiscarded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let clean = try fixture.document(tabs: ["A"])
        let result10 = await authority.execute(fixture.command(.createWorkspace(clean)))
        XCTAssertEqual(result10.disposition, .applied)
        XCTAssertTrue(fixture.probe.replacements.isEmpty, "Creating a workspace discards nothing")
        // Replacing a clean journal (no working copy) discards nothing durable either.
        let edited = try fixture.document(tabs: ["A", Fixture.unreadableTab])
        let result11 = await authority.execute(fixture.command(.replaceWorkingDocument(edited)))
        XCTAssertEqual(result11.disposition, .applied)
        XCTAssertTrue(fixture.probe.replacements.isEmpty)
    }

    // MARK: - Headless (codec-free) guard

    func testHeadlessGuardBacksUpSavedOriginalWhoseTabsTheReplacementDrops() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority(guard: .composeTabLoss())
        let original = try fixture.document(tabs: ["A", Fixture.unreadableTab])
        let result12 = await authority.execute(fixture.command(.createWorkspace(original)))
        XCTAssertEqual(result12.disposition, .applied)
        let reduced = try fixture.document(tabs: ["A"], name: "Reduced by another process")
        let result13 = await authority.execute(fixture.command(.replaceWorkingDocument(reduced)))
        XCTAssertEqual(result13.disposition, .applied)

        // A directory at the locator makes publication fail: the save is refused, nothing removed.
        let locator = DomainRecoveryBackup.backupURL(documentURL: original.fileURL, documentBytes: original.documentBytes)
        try FileManager.default.createDirectory(at: locator, withIntermediateDirectories: false)
        let refused = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(refused.errorCode, .recoveryBackupRequired)
        XCTAssertEqual(try Data(contentsOf: original.fileURL), original.documentBytes)
        XCTAssertTrue(Fixture.isDirectory(locator))

        try FileManager.default.removeItem(at: locator)
        let saved = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(saved.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: original.fileURL), reduced.documentBytes)
        XCTAssertEqual(try Data(contentsOf: locator), original.documentBytes)
    }

    func testHeadlessRawEditThatKeepsEveryTabNeedsNoBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority(guard: .composeTabLoss())
        let original = try fixture.document(tabs: ["A", Fixture.unreadableTab])
        let result14 = await authority.execute(fixture.command(.createWorkspace(original)))
        XCTAssertEqual(result14.disposition, .applied)
        let renamed = try fixture.document(tabs: ["A", Fixture.unreadableTab], name: "Renamed raw")
        let result15 = await authority.execute(fixture.command(.replaceWorkingDocument(renamed)))
        XCTAssertEqual(result15.disposition, .applied)
        let result16 = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(result16.disposition, .applied)
        XCTAssertEqual(try fixture.backupFiles().count, 0)
    }

    // MARK: - Backup locator rules

    func testPreserveUsesFullDigestAndIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let documentURL = fixture.workspaceDirectory.appendingPathComponent("workspace.json")
        let bytes = Data("original".utf8)
        let first = try DomainRecoveryBackup.preserve(documentBytes: bytes, documentURL: documentURL)
        XCTAssertEqual(first.lastPathComponent, "workspace.unreadable-\(DomainContentDigest.sha256(bytes)).json")
        XCTAssertEqual(try DomainRecoveryBackup.preserve(documentBytes: bytes, documentURL: documentURL), first)
        XCTAssertEqual(try fixture.backupFiles().count, 1)
    }

    func testLegacyShortLocatorCountsOnlyWithMatchingFullDigest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let documentURL = fixture.workspaceDirectory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: fixture.workspaceDirectory, withIntermediateDirectories: true)
        let bytes = Data("original".utf8)
        let legacy = DomainRecoveryBackup.legacyBackupURL(documentURL: documentURL, documentBytes: bytes)

        try Data("other original sharing the prefix".utf8).write(to: legacy)
        XCTAssertNil(DomainRecoveryBackup.verifiedBackupURL(documentURL: documentURL, documentBytes: bytes))
        let published = try DomainRecoveryBackup.preserve(documentBytes: bytes, documentURL: documentURL)
        XCTAssertNotEqual(published, legacy)
        XCTAssertEqual(try Data(contentsOf: legacy), Data("other original sharing the prefix".utf8), "Never overwritten")

        try FileManager.default.removeItem(at: published)
        try bytes.write(to: legacy)
        XCTAssertEqual(DomainRecoveryBackup.verifiedBackupURL(documentURL: documentURL, documentBytes: bytes), legacy)
    }

    func testConflictingEntriesAreNeverRemovedOrFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let documentURL = fixture.workspaceDirectory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: fixture.workspaceDirectory, withIntermediateDirectories: true)
        let bytes = Data("original".utf8)
        let locator = DomainRecoveryBackup.backupURL(documentURL: documentURL, documentBytes: bytes)

        let target = fixture.root.appendingPathComponent("symlink-target")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: locator, withDestinationURL: target)
        XCTAssertThrowsError(try DomainRecoveryBackup.preserve(documentBytes: bytes, documentURL: documentURL)) {
            XCTAssertEqual($0 as? DomainRecoveryBackupError, .conflictingEntry(locator.lastPathComponent))
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
        try FileManager.default.removeItem(at: locator)

        try FileManager.default.createDirectory(at: locator, withIntermediateDirectories: false)
        XCTAssertThrowsError(try DomainRecoveryBackup.preserve(documentBytes: bytes, documentURL: documentURL))
        XCTAssertTrue(Fixture.isDirectory(locator))
    }

    func testCorruptCopyAtFullDigestLocatorIsReplacedAndVerified() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let documentURL = fixture.workspaceDirectory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: fixture.workspaceDirectory, withIntermediateDirectories: true)
        let bytes = Data("original".utf8)
        let locator = DomainRecoveryBackup.backupURL(documentURL: documentURL, documentBytes: bytes)
        try Data("truncat".utf8).write(to: locator)

        XCTAssertEqual(try DomainRecoveryBackup.preserve(documentBytes: bytes, documentURL: documentURL), locator)
        XCTAssertEqual(try Data(contentsOf: locator), bytes)
    }

    func testComposeTabLossDetection() throws {
        func doc(_ tabs: Any?, stashed: [String] = []) throws -> Data {
            var object: [String: Any] = ["id": UUID().uuidString]
            if let tabs { object["composeTabs"] = tabs }
            object["stashedTabs"] = stashed.map { ["tab": ["id": $0]] }
            return try JSONSerialization.data(withJSONObject: object)
        }
        let ab = try doc([["id": "a"], ["id": "b"]])
        XCTAssertFalse(DomainRecoveryBackup.replacementDropsComposeTabs(discarded: ab, replacement: try doc([["id": "b"], ["id": "a"]])))
        XCTAssertTrue(DomainRecoveryBackup.replacementDropsComposeTabs(discarded: ab, replacement: try doc([["id": "a"]])))
        XCTAssertFalse(DomainRecoveryBackup.replacementDropsComposeTabs(discarded: ab, replacement: try doc([["id": "a"]], stashed: ["b"])))
        XCTAssertTrue(DomainRecoveryBackup.replacementDropsComposeTabs(discarded: try doc("not-an-array"), replacement: ab))
        XCTAssertTrue(DomainRecoveryBackup.replacementDropsComposeTabs(discarded: Data("{".utf8), replacement: ab))
        XCTAssertFalse(DomainRecoveryBackup.replacementDropsComposeTabs(discarded: try doc(nil), replacement: ab))
    }
}

/// Records every replacement the domain asks about. Documents containing the unreadable marker tab
/// need a backup; while `failing`, producing one fails.
private final class ReplacementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    private var recorded: [DomainDurableReplacement] = []

    var replacements: [DomainDurableReplacement] {
        lock.withLock { recorded }
    }

    func setFailing(_ value: Bool) {
        lock.withLock { failing = value }
    }

    func protect(_ replacement: DomainDurableReplacement) throws {
        let isFailing = lock.withLock {
            recorded.append(replacement)
            return failing
        }
        guard String(decoding: replacement.discardedBytes, as: UTF8.self).contains(Fixture.unreadableTab) else { return }
        if isFailing {
            throw DomainRecoveryBackupError.writeFailed("injected_backup_failure")
        }
        try DomainRecoveryBackup.preserve(documentBytes: replacement.discardedBytes, documentURL: replacement.documentURL)
    }
}

private struct Fixture {
    static let unreadableTab = "UNREADABLE-TAB"

    let root: URL
    let workspaceID = UUID()
    let probe = ReplacementProbe()

    var workspaceDirectory: URL {
        root.appendingPathComponent("Workspaces/\(workspaceID.uuidString)", isDirectory: true)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RecoveryBackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func authority(guard durableGuard: DomainDurableReplacementGuard? = nil) -> DomainWorkspaceContextAuthority {
        let probe = probe
        let configuration = DomainRuntimeConfiguration(
            mode: .app,
            profileIdentifier: "recovery-backup",
            storageDirectory: root,
            workspaceStorageDirectory: root.appendingPathComponent("Workspaces"),
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("tmp"),
            externalReloadInterval: nil,
            durableReplacementGuard: durableGuard ?? DomainDurableReplacementGuard { try probe.protect($0) }
        )
        let identity = DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 0, mode: .app, createdAt: Date())
        return .init(identity: identity, persistence: .init(configuration: configuration, identity: identity), metrics: .disabled)
    }

    func command(_ command: DomainWorkspaceCommand) -> DomainWorkspaceCommandEnvelope {
        .init(operationID: UUID(), origin: .appPresentation(windowID: 1), command: command)
    }

    /// Tab IDs are derived from their names so the same tab keeps its identity across documents.
    func document(tabs: [String], name: String = "Workspace") throws -> DomainWorkspaceDocument {
        let composeTabs: [[String: Any]] = tabs.map { tabName in
            ["id": Self.tabID(tabName).uuidString, "name": tabName]
        }
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "name": name,
            "schemaVersion": 1,
            "repoPaths": ["/private-repository"],
            "isSystemWorkspace": false,
            "composeTabs": composeTabs,
            "activeComposeTabID": Self.tabID(tabs[0]).uuidString
        ]
        return try .decode(
            documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            fileURL: workspaceDirectory.appendingPathComponent("workspace.json")
        )
    }

    func verifiedBackup(of document: DomainWorkspaceDocument) -> URL? {
        DomainRecoveryBackup.verifiedBackupURL(documentURL: document.fileURL, documentBytes: document.documentBytes)
    }

    func backupFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: workspaceDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: workspaceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(DomainRecoveryBackup.fileNamePrefix) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func tabID(_ name: String) -> UUID {
        let digest = DomainContentDigest.sha256(Data(name.utf8))
        let hex = Array(digest.prefix(32))
        let formatted = "\(String(hex[0 ..< 8]))-\(String(hex[8 ..< 12]))-\(String(hex[12 ..< 16]))-\(String(hex[16 ..< 20]))-\(String(hex[20 ..< 32]))"
        return UUID(uuidString: formatted)!
    }
}
