import Foundation
@testable import RepoPrompt
import XCTest

final class AgentPermissionSecureStoreTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        encoder.outputFormatting = [.sortedKeys]
    }

    func testPlainDocumentReadUsesCanonicalPlainOnly() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
                bashToolEnabled: true
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .fullAccess)
        XCTAssertEqual(permissions.bashToolEnabled, true)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertNil(store.diagnostic(for: .codex))
    }

    func testMissingSubagentDocumentCreatesAndSavesSafeManagedPolicy() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertEqual(secureStrings.plainSaveAccessModes, [.nonInteractive(reason: .permissionDecision)])

        let saved = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.globalPolicy(), .safeManaged)
        XCTAssertNil(store.diagnostic(for: .subagent))
    }

    func testMissingSubagentPolicyFieldNormalizesToSafeManagedPolicy() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureSubagentPermissionDocument(globalPolicyRaw: nil)
        )
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)

        let saved = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.globalPolicy(), .safeManaged)
        XCTAssertNil(store.diagnostic(for: .subagent))
    }

    func testMissingPlainDocumentCreatesAndSavesProductDefaults() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .autoReview)
        XCTAssertEqual(permissions.bashToolEnabled, true)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertEqual(secureStrings.plainSaveAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertTrue(secureStrings.savedPlainValues.contains { $0.key == key })

        let saved = try decode(SecureCodexPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.permissionLevel(), .autoReview)
        XCTAssertEqual(saved.bashToolEnabled, true)
        XCTAssertNil(store.diagnostic(for: .codex))
    }

    func testMissingCodexFieldsNormalizeToProductDefaults() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalReviewerRaw: nil,
                bashToolEnabled: nil
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .autoReview)
        XCTAssertEqual(permissions.bashToolEnabled, true)
        XCTAssertNil(store.diagnostic(for: .codex))

        let saved = try decode(SecureCodexPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.permissionLevel(), .autoReview)
        XCTAssertEqual(saved.bashToolEnabled, true)
    }

    func testNoSecureStoreFallbackUsesProductDefaults() throws {
        let suiteName = "AgentPermissionSecureStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults), .safeManaged)
        XCTAssertTrue(CodexAgentToolPreferences.bashToolEnabled(defaults: defaults))
        XCTAssertEqual(CodexAgentToolPreferences.permissionLevel(defaults: defaults), .autoReview)
    }

    @MainActor
    func testProductDefaultsFlowThroughTopLevelSettingsSnapshot() throws {
        let suiteName = "AgentPermissionSecureStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let secureStrings = FakeSecurePlainStringStore()
        let secureStore = makeStore(secureStrings: secureStrings)
        let snapshots = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: secureStore,
            codexMCPServerEntries: { [] }
        )

        let binding = snapshots.topLevelSettingsControlsBinding(providerID: .codex)

        XCTAssertEqual(binding.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
        XCTAssertEqual(binding.runtimePermission.codexApprovalReviewer, .autoReview)
        XCTAssertEqual(binding.codexTools?.bashToolEnabled, true)
    }

    func testSuccessfulResetPersistsProductDefaultsAcrossRelaunch() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
                bashToolEnabled: false
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertTrue(store.resetAgentPermissionsToSafeDefaults().succeeded)
        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertEqual(store.codexPermissions().permissionLevel(), .autoReview)
        XCTAssertEqual(store.codexPermissions().bashToolEnabled, true)

        let saved = try decode(SecureCodexPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.permissionLevel(), .autoReview)
        XCTAssertEqual(saved.bashToolEnabled, true)

        let restartedStore = makeStore(secureStrings: secureStrings)
        XCTAssertEqual(restartedStore.codexPermissions().permissionLevel(), .autoReview)
        XCTAssertEqual(restartedStore.codexPermissions().bashToolEnabled, true)
    }

    func testMissingPlainDocumentWriteFailureFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore(saveError: KeychainService.KeychainError.invalidData)
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .keychainWriteFailed)
    }

    func testMalformedSubagentPlainDocumentFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        secureStrings.plainValues[key] = "{not-json"
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .subagent)?.kind, .decodeFailed)
    }

    func testSubagentReadFailureFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore(plainGetError: KeychainService.KeychainError.interactionNotAllowed)
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertEqual(store.diagnostic(for: .subagent)?.kind, .keychainInteractionNotAllowed)
    }

    func testMalformedCodexPlainDocumentFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = "{not-json"
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .decodeFailed)
    }

    func testMalformedPlainDocumentFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.claude.storageKey
        secureStrings.plainValues[key] = "{not-json"
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.claudePermissions()

        XCTAssertEqual(permissions.permissionLevel(), .requireApproval)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(permissions.mcpStrictModeEnabled, true)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .claude)?.kind, .decodeFailed)
    }

    func testUnsupportedFuturePlainSchemaFailsClosed() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                schemaVersion: SecureCodexPermissionDocument.currentSchemaVersion + 1,
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                bashToolEnabled: true
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .unsupportedFutureSchema)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
    }

    @MainActor
    func testCodexPermissionReadInteractionDeniedFailsClosedAndMarksDiagnosticsDegraded() throws {
        let secureStrings = FakeSecurePlainStringStore(plainGetError: KeychainService.KeychainError.interactionNotAllowed)
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])

        let diagnostic = try XCTUnwrap(store.diagnostic(for: .codex))
        XCTAssertEqual(diagnostic.domain, .codex)
        XCTAssertEqual(diagnostic.kind, .keychainInteractionNotAllowed)
        XCTAssertTrue(diagnostic.message.contains("codex"))
        XCTAssertFalse(diagnostic.message.contains(AgentPermissionSecureDomain.codex.storageKey))
        XCTAssertTrue(AgentPermissionStorageDiagnosticsViewModel.isDegrading(kind: diagnostic.kind))

        let viewModel = AgentPermissionStorageDiagnosticsViewModel(
            securePermissions: store,
            notificationCenter: NotificationCenter()
        )
        XCTAssertTrue(viewModel.isSecurePermissionStorageDegraded)
        XCTAssertEqual(viewModel.storageDiagnostics.map(\.kind), [.keychainInteractionNotAllowed])
    }

    func testAccessModesCapturedForPlainReadsWritesAndDeletesOnly() {
        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        _ = store.codexPermissions()
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertEqual(secureStrings.plainSaveAccessModes, [.nonInteractive(reason: .permissionDecision)])

        XCTAssertTrue(store.updateCodexPermissions { document in
            document.bashToolEnabled = false
        })
        XCTAssertEqual(secureStrings.plainSaveAccessModes.last, .interactive)

        secureStrings.failSaveKeys = Set(AgentPermissionSecureDomain.allCases.map(\.storageKey))
        let resetResult = store.resetAgentPermissionsToSafeDefaults()

        XCTAssertFalse(resetResult.succeeded)
        XCTAssertEqual(Set(resetResult.failedDomains), Set(AgentPermissionSecureDomain.allCases))
        XCTAssertEqual(secureStrings.plainDeleteAccessModes, Array(repeating: .interactive, count: AgentPermissionSecureDomain.allCases.count))
        XCTAssertEqual(store.codexPermissions().permissionLevel(), .defaultPermission)
        XCTAssertEqual(store.codexPermissions().bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .keychainWriteFailed)

        secureStrings.failSaveKeys.removeAll()
        let restartedStore = makeStore(secureStrings: secureStrings)
        let restartedPermissions = restartedStore.codexPermissions()
        XCTAssertEqual(restartedPermissions.permissionLevel(), .autoReview)
        XCTAssertEqual(restartedPermissions.bashToolEnabled, true)
        XCTAssertNil(restartedStore.diagnostic(for: .codex))
    }

    func testUpdateWriteFailureForcesEffectiveCacheFailClosed() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
                bashToolEnabled: true
            )
        )
        let store = makeStore(secureStrings: secureStrings)
        XCTAssertEqual(store.codexPermissions().permissionLevel(), .fullAccess)
        XCTAssertEqual(store.codexPermissions().bashToolEnabled, true)

        secureStrings.failSaveKeys = [key]
        XCTAssertFalse(store.updateCodexPermissions { document in
            document.approvalPolicyRaw = CodexAgentToolPreferences.ApprovalPolicy.onFailure.persistedValue
        })

        let effective = store.codexPermissions()
        XCTAssertEqual(effective.permissionLevel(), .defaultPermission)
        XCTAssertEqual(effective.bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .keychainWriteFailed)
    }

    private func makeStore(
        secureStrings: FakeSecurePlainStringStore,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> AgentPermissionSecureStore {
        AgentPermissionSecureStore(
            secureStrings: secureStrings,
            notificationCenter: notificationCenter,
            now: { Date(timeIntervalSince1970: 1234) }
        )
    }

    private func encode(_ document: some Encodable) throws -> String {
        let data = try encoder.encode(document)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func decode<Document: Decodable>(_ type: Document.Type, from payload: String?) throws -> Document {
        let payload = try XCTUnwrap(payload)
        return try decoder.decode(Document.self, from: Data(payload.utf8))
    }
}

private final class FakeSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches: Bool

    var plainValues: [String: String] = [:]
    var plainGetError: Error?
    var saveError: Error?
    var failSaveKeys: Set<String> = []

    private(set) var plainGetAccessModes: [KeychainAccessMode] = []
    private(set) var plainSaveAccessModes: [KeychainAccessMode] = []
    private(set) var plainDeleteAccessModes: [KeychainAccessMode] = []
    private(set) var savedPlainValues: [(key: String, value: String)] = []

    init(
        plainPayload: String? = nil,
        plainGetError: Error? = nil,
        saveError: Error? = nil,
        persistsValuesAcrossLaunches: Bool = true
    ) {
        if let plainPayload {
            plainValues[AgentPermissionSecureDomain.codex.storageKey] = plainPayload
        }
        self.plainGetError = plainGetError
        self.saveError = saveError
        self.persistsValuesAcrossLaunches = persistsValuesAcrossLaunches
    }

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        plainGetAccessModes.append(accessMode)
        if let plainGetError {
            throw plainGetError
        }
        return plainValues[account.identifier]
    }

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode
    ) throws {
        plainSaveAccessModes.append(accessMode)
        if let saveError {
            throw saveError
        }
        if failSaveKeys.contains(account.identifier) {
            throw KeychainService.KeychainError.invalidData
        }
        plainValues[account.identifier] = value
        savedPlainValues.append((key: account.identifier, value: value))
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        plainDeleteAccessModes.append(accessMode)
        plainValues.removeValue(forKey: account.identifier)
    }
}
