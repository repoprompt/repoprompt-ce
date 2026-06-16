import Foundation

// SEARCH-HELPER: Secure Agent Permission Storage, Keychain-backed permission documents, fail-closed permissions

/// Permission storage domains persisted as one canonical plain JSON secure document each.
enum AgentPermissionSecureDomain: String, CaseIterable, Hashable {
    case subagent
    case codex
    case claude
    case openCode
    case cursor

    var secureStorageAccount: SecureStorageAccount {
        switch self {
        case .subagent:
            .agentPermissionSubagentDocument
        case .codex:
            .agentPermissionCodexDocument
        case .claude:
            .agentPermissionClaudeDocument
        case .openCode:
            .agentPermissionOpenCodeDocument
        case .cursor:
            .agentPermissionCursorDocument
        }
    }

    var storageKey: String {
        secureStorageAccount.identifier
    }
}

struct AgentPermissionStorageDiagnostic: Equatable {
    enum Kind: Equatable {
        case keychainReadFailed
        case keychainWriteFailed
        case keychainInteractionNotAllowed
        case keychainAuthenticationFailed
        case decodeFailed
        case unsupportedFutureSchema
    }

    let domain: AgentPermissionSecureDomain
    let kind: Kind
    let message: String
    let occurredAt: Date
}

struct AgentPermissionStorageResetResult: Equatable {
    let succeededDomains: [AgentPermissionSecureDomain]
    let failedDomains: [AgentPermissionSecureDomain]

    var succeeded: Bool {
        failedDomains.isEmpty
    }
}

extension Notification.Name {
    static let agentPermissionSecureStoreDidChange = Notification.Name("RepoPrompt.agentPermissionSecureStoreDidChange")
    static let agentPermissionSecureStoreDiagnosticsDidChange = Notification.Name("RepoPrompt.agentPermissionSecureStoreDiagnosticsDidChange")
}

enum AgentPermissionSecureStoreNotificationKey {
    static let domain = "domain"
    static let writeSucceeded = "writeSucceeded"
}

struct SecureSubagentPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var updatedAt: Date
    var globalPolicyRaw: String?
    var providerPermissionLevelsRawByProviderID: [String: String]?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        globalPolicyRaw: String? = AgentSubagentPermissionPolicy.safeManaged.rawValue,
        providerPermissionLevelsRawByProviderID: [String: String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.globalPolicyRaw = globalPolicyRaw
        self.providerPermissionLevelsRawByProviderID = providerPermissionLevelsRawByProviderID
    }

    static func failClosedDocument(now: Date = Date()) -> SecureSubagentPermissionDocument {
        SecureSubagentPermissionDocument(updatedAt: now)
    }

    func globalPolicy() -> AgentSubagentPermissionPolicy {
        AgentSubagentPermissionPolicy(rawValue: globalPolicyRaw ?? "") ?? .safeManaged
    }

    func providerPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        guard let raw = providerPermissionLevelsRawByProviderID?[providerID.rawValue],
              let level = AgentProviderPermissionLevelID(providerID: providerID, subagentRawValue: raw)
        else {
            return AgentProviderPermissionLevelID.subagentDefault(for: providerID)
        }
        return level
    }
}

struct SecureCodexPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var approvalPolicyRaw: String?
    var sandboxModeRaw: String?
    var approvalReviewerRaw: String?
    var bashToolEnabled: Bool?
    var mcpServerTogglesByNormalizedName: [String: Bool]?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        approvalPolicyRaw: String? = CodexAgentToolPreferences.ApprovalPolicy.onRequest.persistedValue,
        sandboxModeRaw: String? = CodexAgentToolPreferences.SandboxMode.workspaceWrite.persistedValue,
        approvalReviewerRaw: String? = CodexAgentToolPreferences.ApprovalReviewer.autoReview.persistedValue,
        bashToolEnabled: Bool? = true,
        mcpServerTogglesByNormalizedName: [String: Bool]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.approvalPolicyRaw = approvalPolicyRaw
        self.sandboxModeRaw = sandboxModeRaw
        self.approvalReviewerRaw = approvalReviewerRaw
        self.bashToolEnabled = bashToolEnabled
        self.mcpServerTogglesByNormalizedName = mcpServerTogglesByNormalizedName
    }

    static func failClosedDocument(now: Date = Date()) -> SecureCodexPermissionDocument {
        SecureCodexPermissionDocument(
            updatedAt: now,
            approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
            bashToolEnabled: false
        )
    }

    func approvalPolicy() -> CodexAgentToolPreferences.ApprovalPolicy {
        CodexAgentToolPreferences.ApprovalPolicy(storedValue: approvalPolicyRaw ?? "") ?? .onRequest
    }

    func sandboxMode() -> CodexAgentToolPreferences.SandboxMode {
        CodexAgentToolPreferences.SandboxMode(storedValue: sandboxModeRaw ?? "") ?? .workspaceWrite
    }

    func approvalReviewer() -> CodexAgentToolPreferences.ApprovalReviewer {
        guard let approvalReviewerRaw else { return .autoReview }
        return CodexAgentToolPreferences.ApprovalReviewer(storedValue: approvalReviewerRaw) ?? .user
    }

    func permissionLevel() -> CodexAgentToolPreferences.PermissionLevel {
        CodexAgentToolPreferences.PermissionLevel.from(
            sandbox: sandboxMode(),
            approvalReviewer: approvalReviewer()
        )
    }

    func mcpServerEnabled(normalizedName: String) -> Bool {
        let key = Self.normalizedMCPServerKey(normalizedName)
        return mcpServerTogglesByNormalizedName?[key] ?? false
    }

    static func normalizedMCPServerKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct SecureClaudePermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionModeRaw: String?
    var bashToolEnabled: Bool?
    var mcpStrictModeEnabled: Bool?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionModeRaw: String? = ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode,
        bashToolEnabled: Bool? = true,
        mcpStrictModeEnabled: Bool? = true
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionModeRaw = permissionModeRaw
        self.bashToolEnabled = bashToolEnabled
        self.mcpStrictModeEnabled = mcpStrictModeEnabled
    }

    static func failClosedDocument(now: Date = Date()) -> SecureClaudePermissionDocument {
        SecureClaudePermissionDocument(updatedAt: now, bashToolEnabled: false, mcpStrictModeEnabled: true)
    }

    func permissionMode() -> String {
        Self.normalizedPermissionMode(permissionModeRaw, preserveUnknown: true)
    }

    func permissionLevel() -> ClaudeAgentToolPreferences.PermissionLevel {
        ClaudeAgentToolPreferences.PermissionLevel.from(permissionMode: permissionMode())
    }

    static func normalizedPermissionMode(_ raw: String?, preserveUnknown: Bool) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed.lowercased() {
        case "acceptedits":
            return ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
        case "auto":
            return ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode
        case "bypasspermissions":
            return ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode
        case "default":
            return ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        default:
            return preserveUnknown && !trimmed.isEmpty
                ? trimmed
                : ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        }
    }
}

struct SecureOpenCodePermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionLevelRaw: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionLevelRaw: String? = OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.rawValue
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionLevelRaw = permissionLevelRaw
    }

    static func failClosedDocument(now: Date = Date()) -> SecureOpenCodePermissionDocument {
        SecureOpenCodePermissionDocument(updatedAt: now)
    }

    func permissionLevel() -> OpenCodeAgentToolPreferences.PermissionLevel {
        OpenCodeAgentToolPreferences.PermissionLevel(rawValue: permissionLevelRaw ?? "") ?? .managedDefault
    }

    func sessionModeID() -> String {
        permissionLevel().sessionModeID
    }
}

struct SecureCursorPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionLevelRaw: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionLevelRaw: String? = CursorAgentToolPreferences.PermissionLevel.managedDefault.rawValue
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionLevelRaw = permissionLevelRaw
    }

    static func failClosedDocument(now: Date = Date()) -> SecureCursorPermissionDocument {
        SecureCursorPermissionDocument(updatedAt: now)
    }

    func permissionLevel() -> CursorAgentToolPreferences.PermissionLevel {
        CursorAgentToolPreferences.PermissionLevel.from(rawValue: permissionLevelRaw)
    }
}

final class AgentPermissionSecureStore {
    static let shared = AgentPermissionSecureStore(secureStrings: SecureKeysService())

    private let secureStrings: SecurePlainStringStoring
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date
    private let notificationCenter: NotificationCenter

    private var subagentCache: SecureSubagentPermissionDocument?
    private var codexCache: SecureCodexPermissionDocument?
    private var claudeCache: SecureClaudePermissionDocument?
    private var openCodeCache: SecureOpenCodePermissionDocument?
    private var cursorCache: SecureCursorPermissionDocument?
    private var diagnosticsByDomain: [AgentPermissionSecureDomain: AgentPermissionStorageDiagnostic] = [:]
    private let permissionDecisionAccessMode: KeychainAccessMode = .nonInteractive(reason: .permissionDecision)

    private struct DeferredSideEffects {
        private var requestedDiagnosticsDomains: Set<AgentPermissionSecureDomain> = []
        var diagnosticsNotifications: [AgentPermissionSecureDomain] = []
        var changeNotifications: [(domain: AgentPermissionSecureDomain, writeSucceeded: Bool)] = []

        mutating func requestDiagnosticsNotification(for domain: AgentPermissionSecureDomain) {
            if requestedDiagnosticsDomains.insert(domain).inserted {
                diagnosticsNotifications.append(domain)
            }
        }

        mutating func requestChangeNotification(domain: AgentPermissionSecureDomain, writeSucceeded: Bool) {
            changeNotifications.append((domain, writeSucceeded))
        }
    }

    init(
        secureStrings: SecurePlainStringStoring,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.secureStrings = secureStrings
        self.notificationCenter = notificationCenter
        self.now = now
        encoder.outputFormatting = [.sortedKeys]
    }

    // MARK: - Diagnostics

    func diagnostics() -> [AgentPermissionStorageDiagnostic] {
        withLock { diagnosticsByDomain.values.sorted { $0.domain.rawValue < $1.domain.rawValue } }
    }

    func diagnostic(for domain: AgentPermissionSecureDomain) -> AgentPermissionStorageDiagnostic? {
        withLock { diagnosticsByDomain[domain] }
    }

    func clearCachedDocuments() {
        withLock {
            subagentCache = nil
            codexCache = nil
            claudeCache = nil
            openCodeCache = nil
            cursorCache = nil
        }
    }

    @discardableResult
    func resetAgentPermissionsToSafeDefaults() -> AgentPermissionStorageResetResult {
        withLockAndDeferredSideEffects { effects in
            var succeededDomains: [AgentPermissionSecureDomain] = []
            var failedDomains: [AgentPermissionSecureDomain] = []
            let resetDate = now()

            func record(_ domain: AgentPermissionSecureDomain, _ succeeded: Bool) {
                if succeeded {
                    succeededDomains.append(domain)
                } else {
                    failedDomains.append(domain)
                }
            }

            var subagent = SecureSubagentPermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeSubagent(&subagent)
            record(.subagent, resetLocked(subagent, domain: .subagent, cache: &subagentCache, deferred: &effects))

            var codex = SecureCodexPermissionDocument(updatedAt: resetDate)
            _ = normalizeCodex(&codex)
            record(.codex, resetLocked(codex, domain: .codex, cache: &codexCache, deferred: &effects))

            var claude = SecureClaudePermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeClaude(&claude)
            record(.claude, resetLocked(claude, domain: .claude, cache: &claudeCache, deferred: &effects))

            var openCode = SecureOpenCodePermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeOpenCode(&openCode)
            record(.openCode, resetLocked(openCode, domain: .openCode, cache: &openCodeCache, deferred: &effects))

            var cursor = SecureCursorPermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeCursor(&cursor)
            record(.cursor, resetLocked(cursor, domain: .cursor, cache: &cursorCache, deferred: &effects))

            return AgentPermissionStorageResetResult(
                succeededDomains: succeededDomains,
                failedDomains: failedDomains
            )
        }
    }

    // MARK: - Public reads

    func subagentPermissions() -> SecureSubagentPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadSubagentPermissionsLocked(deferred: &effects)
        }
    }

    func subagentPolicy() -> AgentSubagentPermissionPolicy {
        subagentPermissions().globalPolicy()
    }

    func providerSubagentPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        subagentPermissions().providerPermissionLevel(for: providerID)
    }

    func codexPermissions() -> SecureCodexPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadCodexPermissionsLocked(deferred: &effects)
        }
    }

    func claudePermissions() -> SecureClaudePermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadClaudePermissionsLocked(deferred: &effects)
        }
    }

    func openCodePermissions() -> SecureOpenCodePermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadOpenCodePermissionsLocked(deferred: &effects)
        }
    }

    func cursorPermissions() -> SecureCursorPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadCursorPermissionsLocked(deferred: &effects)
        }
    }

    // MARK: - Public writes

    @discardableResult
    func updateSubagentPermissions(_ mutation: (inout SecureSubagentPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            var document = loadSubagentPermissionsLocked(deferred: &effects)
            mutation(&document)
            normalizeSubagent(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .subagent, cache: &subagentCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateCodexPermissions(_ mutation: (inout SecureCodexPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            var document = loadCodexPermissionsLocked(deferred: &effects)
            mutation(&document)
            normalizeCodex(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .codex, cache: &codexCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateClaudePermissions(_ mutation: (inout SecureClaudePermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            var document = loadClaudePermissionsLocked(deferred: &effects)
            mutation(&document)
            normalizeClaude(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .claude, cache: &claudeCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateOpenCodePermissions(_ mutation: (inout SecureOpenCodePermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            var document = loadOpenCodePermissionsLocked(deferred: &effects)
            mutation(&document)
            normalizeOpenCode(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .openCode, cache: &openCodeCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateCursorPermissions(_ mutation: (inout SecureCursorPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            var document = loadCursorPermissionsLocked(deferred: &effects)
            mutation(&document)
            normalizeCursor(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .cursor, cache: &cursorCache, deferred: &effects)
        }
    }

    @discardableResult
    func setCodexPermissionLevel(_ level: CodexAgentToolPreferences.PermissionLevel) -> Bool {
        updateCodexPermissions { document in
            document.approvalPolicyRaw = level.approvalPolicy.persistedValue
            document.sandboxModeRaw = level.sandboxMode.persistedValue
            document.approvalReviewerRaw = level.approvalReviewer.persistedValue
        }
    }

    @discardableResult
    func setClaudePermissionLevel(_ level: ClaudeAgentToolPreferences.PermissionLevel) -> Bool {
        updateClaudePermissions { document in
            document.permissionModeRaw = level.permissionMode
        }
    }

    @discardableResult
    func setOpenCodePermissionLevel(_ level: OpenCodeAgentToolPreferences.PermissionLevel) -> Bool {
        updateOpenCodePermissions { document in
            document.permissionLevelRaw = level.rawValue
        }
    }

    @discardableResult
    func setCursorPermissionLevel(_ level: CursorAgentToolPreferences.PermissionLevel) -> Bool {
        updateCursorPermissions { document in
            document.permissionLevelRaw = level.rawValue
        }
    }

    // MARK: - Locked loads

    private func loadSubagentPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureSubagentPermissionDocument {
        loadLocked(
            domain: .subagent,
            cache: &subagentCache,
            failClosedDocument: SecureSubagentPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeSubagent,
            deferred: &effects
        )
    }

    private func loadCodexPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureCodexPermissionDocument {
        loadLocked(
            domain: .codex,
            cache: &codexCache,
            missingDocument: SecureCodexPermissionDocument(updatedAt: now()),
            failClosedDocument: SecureCodexPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeCodex,
            deferred: &effects
        )
    }

    private func loadClaudePermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureClaudePermissionDocument {
        loadLocked(
            domain: .claude,
            cache: &claudeCache,
            failClosedDocument: SecureClaudePermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeClaude,
            deferred: &effects
        )
    }

    private func loadOpenCodePermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureOpenCodePermissionDocument {
        loadLocked(
            domain: .openCode,
            cache: &openCodeCache,
            failClosedDocument: SecureOpenCodePermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeOpenCode,
            deferred: &effects
        )
    }

    private func loadCursorPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureCursorPermissionDocument {
        loadLocked(
            domain: .cursor,
            cache: &cursorCache,
            failClosedDocument: SecureCursorPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeCursor,
            deferred: &effects
        )
    }

    private struct StoredDocumentFailure {
        let kind: AgentPermissionStorageDiagnostic.Kind
        let message: String
    }

    private enum StoredDocumentDecodeResult<Document> {
        case success(document: Document, normalized: Bool)
        case failure(StoredDocumentFailure)
    }

    private func loadLocked<Document: Codable>(
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        missingDocument: Document? = nil,
        failClosedDocument: Document,
        normalize: (inout Document) -> Bool,
        deferred effects: inout DeferredSideEffects
    ) -> Document {
        if let cache {
            return cache
        }

        let plainPayload: String?
        do {
            plainPayload = try secureStrings.getPlainValue(
                for: domain.secureStorageAccount,
                accessMode: permissionDecisionAccessMode
            )
        } catch {
            let kind = readFailureKind(for: error)
            return failClosed(
                domain: domain,
                failure: StoredDocumentFailure(kind: kind, message: sanitizedDiagnosticMessage(domain: domain, kind: kind, error: error)),
                failClosedDocument: failClosedDocument,
                cache: &cache,
                deferred: &effects
            )
        }

        guard let payload = plainPayload else {
            var document = missingDocument ?? failClosedDocument
            _ = normalize(&document)
            do {
                try saveDocument(document, domain: domain, accessMode: permissionDecisionAccessMode)
                cache = document
                if clearDiagnostic(for: domain) {
                    effects.requestDiagnosticsNotification(for: domain)
                }
                return document
            } catch {
                let kind = keychainFailureKind(for: error, fallback: .keychainWriteFailed)
                recordDiagnostic(domain: domain, kind: kind, error: error)
                effects.requestDiagnosticsNotification(for: domain)
                cache = failClosedDocument
                return failClosedDocument
            }
        }

        switch decodeStoredDocument(payload, normalize: normalize) {
        case let .success(document, normalized):
            return finishLoadedDocument(
                document,
                normalized: normalized,
                domain: domain,
                cache: &cache,
                deferred: &effects
            )
        case let .failure(plainFailure):
            return failClosed(domain: domain, failure: plainFailure, failClosedDocument: failClosedDocument, cache: &cache, deferred: &effects)
        }
    }

    private func decodeStoredDocument<Document: Codable>(
        _ payload: String,
        normalize: (inout Document) -> Bool
    ) -> StoredDocumentDecodeResult<Document> {
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: Data(payload.utf8))
        } catch {
            return .failure(StoredDocumentFailure(kind: .decodeFailed, message: error.localizedDescription))
        }

        if schemaVersion(of: document) > supportedSchemaVersion(of: document) {
            return .failure(StoredDocumentFailure(
                kind: .unsupportedFutureSchema,
                message: "Unsupported future schema version \(schemaVersion(of: document))."
            ))
        }

        var normalizedDocument = document
        let normalized = normalize(&normalizedDocument)
        return .success(document: normalizedDocument, normalized: normalized)
    }

    private func finishLoadedDocument<Document: Codable>(
        _ document: Document,
        normalized: Bool,
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Document {
        cache = document
        if clearDiagnostic(for: domain) {
            effects.requestDiagnosticsNotification(for: domain)
        }
        if normalized {
            do {
                try saveDocument(document, domain: domain, accessMode: permissionDecisionAccessMode)
            } catch {
                let kind = keychainFailureKind(for: error, fallback: .keychainWriteFailed)
                recordDiagnostic(domain: domain, kind: kind, error: error)
                effects.requestDiagnosticsNotification(for: domain)
                cache = failClosedDocument(for: domain) as? Document
                return cache ?? document
            }
        }
        return document
    }

    private func failClosed<Document>(
        domain: AgentPermissionSecureDomain,
        failure: StoredDocumentFailure,
        failClosedDocument: Document,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Document {
        recordDiagnostic(domain: domain, kind: failure.kind, message: failure.message)
        effects.requestDiagnosticsNotification(for: domain)
        cache = failClosedDocument
        return failClosedDocument
    }

    private func saveLocked<Document: Codable>(
        _ document: Document,
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Bool {
        do {
            try saveDocument(document, domain: domain)
            cache = document
            if clearDiagnostic(for: domain) {
                effects.requestDiagnosticsNotification(for: domain)
            }
            effects.requestChangeNotification(domain: domain, writeSucceeded: true)
            return true
        } catch {
            recordDiagnostic(domain: domain, kind: keychainFailureKind(for: error, fallback: .keychainWriteFailed), error: error)
            effects.requestDiagnosticsNotification(for: domain)
            cache = failClosedDocument(for: domain) as? Document
            effects.requestChangeNotification(domain: domain, writeSucceeded: false)
            return false
        }
    }

    private func resetLocked<Document: Codable>(
        _ document: Document,
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Bool {
        do {
            try saveDocument(document, domain: domain)
            cache = document
            if clearDiagnostic(for: domain) {
                effects.requestDiagnosticsNotification(for: domain)
            }
            effects.requestChangeNotification(domain: domain, writeSucceeded: true)
            return true
        } catch {
            recordDiagnostic(domain: domain, kind: keychainFailureKind(for: error, fallback: .keychainWriteFailed), error: error)
            effects.requestDiagnosticsNotification(for: domain)
            try? secureStrings.deletePlainValue(for: domain.secureStorageAccount, accessMode: .interactive)
            cache = failClosedDocument(for: domain) as? Document
            effects.requestChangeNotification(domain: domain, writeSucceeded: false)
            return false
        }
    }

    private func saveDocument(
        _ document: some Codable,
        domain: AgentPermissionSecureDomain,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        let data = try encoder.encode(document)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw AgentPermissionSecureStoreError.encodingFailed
        }
        try secureStrings.savePlainValue(payload, for: domain.secureStorageAccount, accessMode: accessMode)
    }

    // MARK: - Normalization

    @discardableResult
    private func normalizeSubagent(_ document: inout SecureSubagentPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureSubagentPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureSubagentPermissionDocument.currentSchemaVersion
            changed = true
        }
        if AgentSubagentPermissionPolicy(rawValue: document.globalPolicyRaw ?? "") == nil {
            document.globalPolicyRaw = AgentSubagentPermissionPolicy.safeManaged.rawValue
            changed = true
        }

        let originalLevels = document.providerPermissionLevelsRawByProviderID ?? [:]
        var normalizedLevels: [String: String] = [:]
        for providerID in AgentProviderBindingID.allCases {
            if let raw = originalLevels[providerID.rawValue],
               let level = AgentProviderPermissionLevelID(providerID: providerID, subagentRawValue: raw)
            {
                normalizedLevels[providerID.rawValue] = level.subagentRawValue
            }
        }

        if normalizedLevels != originalLevels {
            document.providerPermissionLevelsRawByProviderID = normalizedLevels.isEmpty ? nil : normalizedLevels
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeCodex(_ document: inout SecureCodexPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureCodexPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureCodexPermissionDocument.currentSchemaVersion
            changed = true
        }
        let approval = CodexAgentToolPreferences.ApprovalPolicy(storedValue: document.approvalPolicyRaw ?? "") ?? .onRequest
        if document.approvalPolicyRaw != approval.persistedValue {
            document.approvalPolicyRaw = approval.persistedValue
            changed = true
        }
        let sandbox = CodexAgentToolPreferences.SandboxMode(storedValue: document.sandboxModeRaw ?? "") ?? .workspaceWrite
        if document.sandboxModeRaw != sandbox.persistedValue {
            document.sandboxModeRaw = sandbox.persistedValue
            changed = true
        }
        let reviewer: CodexAgentToolPreferences.ApprovalReviewer = if let raw = document.approvalReviewerRaw {
            CodexAgentToolPreferences.ApprovalReviewer(storedValue: raw) ?? .user
        } else {
            .autoReview
        }
        if document.approvalReviewerRaw != reviewer.persistedValue {
            document.approvalReviewerRaw = reviewer.persistedValue
            changed = true
        }
        if document.bashToolEnabled == nil {
            document.bashToolEnabled = true
            changed = true
        }
        let originalToggles = document.mcpServerTogglesByNormalizedName ?? [:]
        var normalized: [String: Bool] = [:]
        for (key, value) in originalToggles {
            let normalizedKey = SecureCodexPermissionDocument.normalizedMCPServerKey(key)
            guard !normalizedKey.isEmpty else { continue }
            normalized[normalizedKey] = value
        }
        if normalized != originalToggles {
            document.mcpServerTogglesByNormalizedName = normalized.isEmpty ? nil : normalized
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeClaude(_ document: inout SecureClaudePermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureClaudePermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureClaudePermissionDocument.currentSchemaVersion
            changed = true
        }
        let mode = SecureClaudePermissionDocument.normalizedPermissionMode(document.permissionModeRaw, preserveUnknown: true)
        if document.permissionModeRaw != mode {
            document.permissionModeRaw = mode
            changed = true
        }
        if document.bashToolEnabled == nil {
            document.bashToolEnabled = false
            changed = true
        }
        if document.mcpStrictModeEnabled == nil {
            document.mcpStrictModeEnabled = true
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeOpenCode(_ document: inout SecureOpenCodePermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureOpenCodePermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureOpenCodePermissionDocument.currentSchemaVersion
            changed = true
        }
        let level = OpenCodeAgentToolPreferences.PermissionLevel(rawValue: document.permissionLevelRaw ?? "") ?? .managedDefault
        if document.permissionLevelRaw != level.rawValue {
            document.permissionLevelRaw = level.rawValue
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeCursor(_ document: inout SecureCursorPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureCursorPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureCursorPermissionDocument.currentSchemaVersion
            changed = true
        }
        let level = CursorAgentToolPreferences.PermissionLevel.from(rawValue: document.permissionLevelRaw)
        if document.permissionLevelRaw != level.rawValue {
            document.permissionLevelRaw = level.rawValue
            changed = true
        }
        return changed
    }

    // MARK: - Helpers

    private func supportedSchemaVersion(of document: some Any) -> Int {
        switch document {
        case _ as SecureSubagentPermissionDocument:
            SecureSubagentPermissionDocument.currentSchemaVersion
        case _ as SecureCodexPermissionDocument:
            SecureCodexPermissionDocument.currentSchemaVersion
        case _ as SecureClaudePermissionDocument:
            SecureClaudePermissionDocument.currentSchemaVersion
        case _ as SecureOpenCodePermissionDocument:
            SecureOpenCodePermissionDocument.currentSchemaVersion
        case _ as SecureCursorPermissionDocument:
            SecureCursorPermissionDocument.currentSchemaVersion
        default:
            1
        }
    }

    private func schemaVersion(of document: some Any) -> Int {
        switch document {
        case let value as SecureSubagentPermissionDocument:
            value.schemaVersion
        case let value as SecureCodexPermissionDocument:
            value.schemaVersion
        case let value as SecureClaudePermissionDocument:
            value.schemaVersion
        case let value as SecureOpenCodePermissionDocument:
            value.schemaVersion
        case let value as SecureCursorPermissionDocument:
            value.schemaVersion
        default:
            1
        }
    }

    private func failClosedDocument(for domain: AgentPermissionSecureDomain) -> Any {
        switch domain {
        case .subagent:
            SecureSubagentPermissionDocument.failClosedDocument(now: now())
        case .codex:
            SecureCodexPermissionDocument.failClosedDocument(now: now())
        case .claude:
            SecureClaudePermissionDocument.failClosedDocument(now: now())
        case .openCode:
            SecureOpenCodePermissionDocument.failClosedDocument(now: now())
        case .cursor:
            SecureCursorPermissionDocument.failClosedDocument(now: now())
        }
    }

    private func readFailureKind(for error: Error) -> AgentPermissionStorageDiagnostic.Kind {
        keychainFailureKind(for: error, fallback: .keychainReadFailed)
    }

    private func isAccessDeniedFailure(_ error: Error) -> Bool {
        guard let keychainError = error as? KeychainService.KeychainError else {
            return false
        }
        switch keychainError {
        case .interactionNotAllowed, .authenticationFailed, .userInteractionCancelled:
            return true
        default:
            return false
        }
    }

    private func keychainFailureKind(
        for error: Error,
        fallback: AgentPermissionStorageDiagnostic.Kind
    ) -> AgentPermissionStorageDiagnostic.Kind {
        guard let keychainError = error as? KeychainService.KeychainError else {
            return fallback
        }
        switch keychainError {
        case .interactionNotAllowed:
            return .keychainInteractionNotAllowed
        case .authenticationFailed, .userInteractionCancelled:
            return .keychainAuthenticationFailed
        default:
            return fallback
        }
    }

    private func recordDiagnostic(
        domain: AgentPermissionSecureDomain,
        kind: AgentPermissionStorageDiagnostic.Kind,
        error: Error
    ) {
        recordDiagnostic(domain: domain, kind: kind, message: sanitizedDiagnosticMessage(domain: domain, kind: kind, error: error))
    }

    private func sanitizedDiagnosticMessage(
        domain: AgentPermissionSecureDomain,
        kind: AgentPermissionStorageDiagnostic.Kind,
        error: Error
    ) -> String {
        switch kind {
        case .keychainInteractionNotAllowed:
            "Secure permission storage for \(domain.rawValue) could not be accessed without user interaction. Safe defaults are active."
        case .keychainAuthenticationFailed:
            "Secure permission storage for \(domain.rawValue) could not be authenticated. Safe defaults are active."
        default:
            error.localizedDescription
        }
    }

    private func recordDiagnostic(
        domain: AgentPermissionSecureDomain,
        kind: AgentPermissionStorageDiagnostic.Kind,
        message: String
    ) {
        diagnosticsByDomain[domain] = AgentPermissionStorageDiagnostic(
            domain: domain,
            kind: kind,
            message: message,
            occurredAt: now()
        )
    }

    @discardableResult
    private func clearDiagnostic(for domain: AgentPermissionSecureDomain) -> Bool {
        diagnosticsByDomain.removeValue(forKey: domain) != nil
    }

    private func postChangeNotification(domain: AgentPermissionSecureDomain, writeSucceeded: Bool) {
        notificationCenter.post(
            name: .agentPermissionSecureStoreDidChange,
            object: self,
            userInfo: [
                AgentPermissionSecureStoreNotificationKey.domain: domain.rawValue,
                AgentPermissionSecureStoreNotificationKey.writeSucceeded: writeSucceeded
            ]
        )
    }

    private func postDiagnosticsNotification(domain: AgentPermissionSecureDomain) {
        notificationCenter.post(
            name: .agentPermissionSecureStoreDiagnosticsDidChange,
            object: self,
            userInfo: [
                AgentPermissionSecureStoreNotificationKey.domain: domain.rawValue
            ]
        )
    }

    private func performDeferredSideEffects(_ effects: DeferredSideEffects) {
        for domain in effects.diagnosticsNotifications {
            postDiagnosticsNotification(domain: domain)
        }
        for notification in effects.changeNotifications {
            postChangeNotification(domain: notification.domain, writeSucceeded: notification.writeSucceeded)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func withLockAndDeferredSideEffects<T>(_ body: (inout DeferredSideEffects) -> T) -> T {
        var effects = DeferredSideEffects()
        let result: T = {
            lock.lock()
            defer { lock.unlock() }
            return body(&effects)
        }()
        performDeferredSideEffects(effects)
        return result
    }

    private enum AgentPermissionSecureStoreError: LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                "Failed to encode secure permission document."
            }
        }
    }
}
