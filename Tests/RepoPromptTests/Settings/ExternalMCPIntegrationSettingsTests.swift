import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class ExternalMCPIntegrationSettingsTests: XCTestCase {
    func testEmptyDocumentKeepsLegacyContentDerivedSchemaVersion() {
        let document = GlobalSettingsDocument()

        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        XCTAssertEqual(GlobalSettingsDocument.externalMCPConnectionsSchemaVersion, 8)
        XCTAssertEqual(GlobalSettingsDocument.externalMCPConnectionActivationSchemaVersion, 9)
        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 10)
        XCTAssertNil(document.externalMCPConnections)
        XCTAssertTrue(document.externalMCPWorkspaceAccess.isEmpty)
    }

    func testEnabledFigmaRegistrationPersistsOnlyAppWideNonsecretState() throws {
        let fileURL = try temporarySettingsURL()
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let definition = ExternalMCPIntegrationDefinition.figma(
            autoConnect: false,
            agentModeAccessDefault: .deny
        )

        try fileStore.save(GlobalSettingsDocument(externalMCPConnections: [definition]))

        let data = try Data(contentsOf: fileURL)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reloaded = try XCTUnwrap(fileStore.load().externalMCPConnections?.first)

        XCTAssertEqual(root["schemaVersion"] as? Int, GlobalSettingsDocument.externalMCPConnectionsSchemaVersion)
        XCTAssertEqual(reloaded.repoPromptActivation, .enabled)
        XCTAssertTrue(reloaded.autoConnect)
        XCTAssertEqual(reloaded.agentModeAccessDefault, .allow)
        XCTAssertTrue(json.contains("\"provider\" : \"figma\""))
        XCTAssertFalse(json.contains("autoConnect"))
        XCTAssertFalse(json.contains("agentModeAccessDefault"))
        XCTAssertFalse(json.contains("externalMCPAccessByWorkspaceID"))
        XCTAssertFalse(json.contains("repoPromptActivation"))
        assertContainsNoSecrets(json)
    }

    func testLegacyPolicyKeysDecodeSafelyDoNotControlFigmaAndAreStrippedOnNextSave() throws {
        let fileURL = try temporarySettingsURL()
        let workspaceID = UUID().uuidString
        let original = Data("""
        {"schemaVersion":5,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"settingsManaged","autoConnect":{"future":false},"agentModeAccessDefault":"future-policy"}],"externalMCPAccessByWorkspaceID":{"\(workspaceID)":{"futureShape":true}},"globalDefaults":{}}
        """.utf8)
        try original.write(to: fileURL)
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        let document = try fileStore.load()
        let definition = try XCTUnwrap(document.externalMCPConnections?.first)
        XCTAssertTrue(definition.autoConnect)
        XCTAssertEqual(definition.agentModeAccessDefault, .allow)
        XCTAssertTrue(document.externalMCPWorkspaceAccess.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), original, "Loading alone must not rewrite user state")

        try fileStore.save(document)
        let rewritten = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        XCTAssertFalse(rewritten.contains("autoConnect"))
        XCTAssertFalse(rewritten.contains("agentModeAccessDefault"))
        XCTAssertFalse(rewritten.contains("externalMCPAccessByWorkspaceID"))
    }

    func testSettingsManagedCleanupTombstoneIsRetained() throws {
        let fileURL = try temporarySettingsURL()
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let tombstone = ExternalMCPIntegrationDefinition.figma(repoPromptActivation: .disabled)

        try fileStore.save(GlobalSettingsDocument(externalMCPConnections: [tombstone]))

        let data = try Data(contentsOf: fileURL)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(tombstone.isCleanupTombstone)
        XCTAssertEqual(try fileStore.load().externalMCPConnections?.first, tombstone)
        XCTAssertEqual(
            root["schemaVersion"] as? Int,
            GlobalSettingsDocument.externalMCPConnectionActivationSchemaVersion
        )
        XCTAssertTrue(json.contains("repoPromptActivation"))
        XCTAssertFalse(json.contains("autoConnect"))
        XCTAssertFalse(json.contains("agentModeAccessDefault"))
        assertContainsNoSecrets(json)
    }

    func testDisabledAdoptedImportIsRejectedByDirectDecode() throws {
        let data = Data(#"{"schemaVersion":9,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"adoptedImport","repoPromptActivation":"disabled"}],"globalDefaults":{}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder.repoPromptSettings.decode(GlobalSettingsDocument.self, from: data)) { error in
            XCTAssertEqual(error as? ExternalMCPIntegrationSettingsDecodingError, .unsupportedDefinition)
        }
    }

    func testDisabledAdoptedImportIsDroppedAtSaveBoundary() throws {
        let fileURL = try temporarySettingsURL()
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        var document = GlobalSettingsDocument()
        document.externalMCPConnections = [.adoptedFigmaImport(repoPromptActivation: .disabled)]

        try fileStore.save(document)

        XCTAssertNil(try fileStore.load().externalMCPConnections)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertNil(root["externalMCPConnections"])
        XCTAssertEqual(root["schemaVersion"] as? Int, GlobalSettingsDocument.baselineSchemaVersion)
    }

    func testDisabledAdoptedImportIsBlockedAndPreservedOnDisk() throws {
        let fileURL = try temporarySettingsURL()
        let original = Data(#"{"schemaVersion":9,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"adoptedImport","repoPromptActivation":"disabled"}],"globalDefaults":{}}"#.utf8)
        try original.write(to: fileURL)
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        XCTAssertThrowsError(try fileStore.load()) { error in
            XCTAssertEqual(error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError, .externalMCPConnectionSettingsInvalid)
        }
        XCTAssertEqual(fileStore.blockReason, .invalidExternalMCPSettings(.unsupportedDefinition))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testLegacyV4FigmaRegistrationIsRetainedOnNextSave() throws {
        let fileURL = try temporarySettingsURL()
        let original = Data(#"{"schemaVersion":4,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"settingsManaged","repoPromptActivation":"disabled"}],"globalDefaults":{}}"#.utf8)
        try original.write(to: fileURL)
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        let document = try fileStore.load()
        XCTAssertEqual(document.externalMCPConnections?.first, .figma(repoPromptActivation: .disabled))

        try fileStore.save(document)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(
            root["schemaVersion"] as? Int,
            GlobalSettingsDocument.externalMCPConnectionActivationSchemaVersion
        )
    }

    func testInvalidActivationStillFailsClosedAndPreservesOriginalFile() throws {
        let fileURL = try temporarySettingsURL()
        let original = Data(#"{"schemaVersion":9,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"settingsManaged","repoPromptActivation":"paused"}],"globalDefaults":{}}"#.utf8)
        try original.write(to: fileURL)
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        XCTAssertThrowsError(try fileStore.load()) { error in
            XCTAssertEqual(
                error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError,
                .externalMCPConnectionSettingsInvalid
            )
        }
        XCTAssertEqual(fileStore.blockReason, .invalidExternalMCPSettings(.invalidActivation))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testUnknownExternalDefinitionFieldIsPreservedAndCategorized() throws {
        let fileURL = try temporarySettingsURL()
        let original = Data(#"{"schemaVersion":8,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"settingsManaged","unexpected":true}],"globalDefaults":{}}"#.utf8)
        try original.write(to: fileURL)
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        XCTAssertThrowsError(try fileStore.load())
        XCTAssertEqual(fileStore.blockReason, .invalidExternalMCPSettings(.unknownDefinitionField))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testDuplicateExternalDefinitionsStillFailClosed() throws {
        let fileURL = try temporarySettingsURL()
        let original = Data(#"{"schemaVersion":8,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"settingsManaged"},{"provider":"figma","serverName":"figma","origin":"settingsManaged"}],"globalDefaults":{}}"#.utf8)
        try original.write(to: fileURL)

        XCTAssertThrowsError(try GlobalSettingsFileStore(fileURL: fileURL).load()) { error in
            XCTAssertEqual(
                error as? GlobalSettingsFileStore.GlobalSettingsFileStoreError,
                .externalMCPConnectionSettingsInvalid
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testAppWideResolutionIgnoresWorkspaceWindowAndSessionHierarchy() {
        let enabled = ExternalMCPIntegrationDefinition.figma()
        let combinations: [(ExternalMCPAgentSessionPolicy, ExternalMCPAgentAccessPolicy?, ExternalMCPAgentAccessPolicy)] = [
            (.normal, nil, .inherit),
            (.normal, .deny, .deny),
            (.safeManagedChild, .deny, .deny),
            (.headless, .deny, .deny)
        ]

        for (session, window, workspace) in combinations {
            XCTAssertEqual(
                resolveExternalMCPAgentAccess(
                    definition: enabled,
                    runtimeAvailability: .available,
                    sessionPolicy: session,
                    windowOverride: window,
                    workspaceOverride: workspace
                ),
                .init(isAllowed: true, source: .appDefault)
            )
        }
    }

    func testAppWideResolutionRetainsOnlyRuntimeAndConnectionGates() {
        let enabled = ExternalMCPIntegrationDefinition.figma()
        let disabled = ExternalMCPIntegrationDefinition.figma(repoPromptActivation: .disabled)

        XCTAssertEqual(
            resolveExternalMCPAgentAccess(definition: nil, runtimeAvailability: .available),
            .init(isAllowed: false, source: .unavailable)
        )
        XCTAssertEqual(
            resolveExternalMCPAgentAccess(definition: enabled, runtimeAvailability: .unavailable),
            .init(isAllowed: false, source: .unavailable)
        )
        XCTAssertEqual(
            resolveExternalMCPAgentAccess(definition: enabled, runtimeAvailability: .disabled),
            .init(isAllowed: false, source: .runtimeDisabled)
        )
        XCTAssertEqual(
            resolveExternalMCPAgentAccess(definition: enabled, runtimeAvailability: .externallyExplicitlyDisabled),
            .init(isAllowed: false, source: .externalExplicitDisable)
        )
        XCTAssertEqual(
            resolveExternalMCPAgentAccess(definition: disabled, runtimeAvailability: .available),
            .init(isAllowed: false, source: .connectionDisabled)
        )
    }

    func testLegacyV6FigmaDocumentCanBeSafelyImportedAfterBackup() throws {
        let fileURL = try temporarySettingsURL()
        let original = Data(#"{"schemaVersion":6,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"settingsManaged"}],"globalDefaults":{"discoverAgentRaw":"legacy"}}"#.utf8)
        try original.write(to: fileURL)
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

        XCTAssertThrowsError(try fileStore.load())
        XCTAssertEqual(fileStore.blockReason, .incompatibleSchema)
        XCTAssertTrue(fileStore.performUserInitiatedCompatibleImport())

        let imported = try fileStore.load()
        XCTAssertNil(imported.externalMCPConnections)
        XCTAssertEqual(imported.globalDefaults.discoverAgentRaw, "legacy")
        let backups = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent().appendingPathComponent("Backups"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
    }

    func testFailedInvalidExternalMCPImportRetainsRetryableBlockReason() throws {
        let fileURL = try temporarySettingsURL()
        let original = Data(#"{"schemaVersion":8,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-08-27T12:00:00Z","copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"externalMCPConnections":[{"provider":"figma","serverName":"figma","origin":"settingsManaged","unexpected":true}],"globalDefaults":{}}"#.utf8)
        try original.write(to: fileURL)
        var shouldFail = true
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL, atomicWriter: { data, destination in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: destination, options: .atomic)
        })

        XCTAssertThrowsError(try fileStore.load())
        let expectedReason = GlobalSettingsPersistenceBlockReason.invalidExternalMCPSettings(.unknownDefinitionField)
        XCTAssertEqual(fileStore.blockReason, expectedReason)
        XCTAssertFalse(fileStore.performUserInitiatedCompatibleImport())
        XCTAssertEqual(fileStore.blockReason, expectedReason)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)

        shouldFail = false
        XCTAssertTrue(fileStore.performUserInitiatedCompatibleImport())
        XCTAssertNil(try fileStore.load().externalMCPConnections)
    }

    func testStoreAndWindowPolicyCompatibilityAPIsRetainNoStateOrPersistence() throws {
        let fileURL = try temporarySettingsURL()
        let store = try GlobalSettingsStore(
            defaults: isolatedDefaults(),
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let workspaceID = UUID()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let dataBeforeLegacyWrites = try Data(contentsOf: fileURL)

        XCTAssertTrue(store.setExternalMCPWorkspaceAccessPolicy(.deny, for: .figma, workspaceID: workspaceID))
        XCTAssertEqual(store.externalMCPWorkspaceAccessPolicy(for: .figma, workspaceID: workspaceID), .inherit)
        let windowStore = WindowSettingsManager(windowID: 1, store: store)
        windowStore.setTransientExternalMCPAccessOverride(.deny, for: .figma, workspaceID: workspaceID)
        XCTAssertNil(windowStore.transientExternalMCPAccessOverride(for: .figma, workspaceID: workspaceID))
        XCTAssertEqual(try Data(contentsOf: fileURL), dataBeforeLegacyWrites)
        XCTAssertEqual(
            windowStore.resolvedExternalMCPAgentAccess(
                for: .figma,
                workspaceID: workspaceID,
                runtimeAvailability: .available,
                sessionPolicy: .safeManagedChild
            ),
            .init(isAllowed: true, source: .appDefault)
        )
    }

    func testStoreRejectsDisabledAdoptedImportsButRetainsCleanupTombstones() throws {
        let store = try GlobalSettingsStore(
            defaults: isolatedDefaults(),
            fileStore: GlobalSettingsFileStore(fileURL: temporarySettingsURL())
        )

        XCTAssertFalse(store.setExternalMCPIntegration(.adoptedFigmaImport(repoPromptActivation: .disabled)))
        XCTAssertNil(store.externalMCPIntegration(for: .figma))
        XCTAssertTrue(store.setExternalMCPIntegration(.figma(repoPromptActivation: .disabled)))
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), .figma(repoPromptActivation: .disabled))
    }

    private func assertContainsNoSecrets(
        _ json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(json.localizedCaseInsensitiveContains("token"), file: file, line: line)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("oauth"), file: file, line: line)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("secret"), file: file, line: line)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("https://"), file: file, line: line)
    }

    private func temporarySettingsURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalMCPIntegrationSettingsTests.\(UUID().uuidString)", isDirectory: true)
        let settingsDirectory = directory.appendingPathComponent("Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return settingsDirectory.appendingPathComponent("globalSettings.json")
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "ExternalMCPIntegrationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private extension JSONDecoder {
    static var repoPromptSettings: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
