import Foundation

enum SecureStorageIdentityMigrationRecordState: Equatable {
    case absent
    case copied
    case verified
    case interactionRequired
    case userInteractionCancelled
    case authenticationFailed
    case failed

    var isReady: Bool {
        switch self {
        case .absent, .copied, .verified:
            true
        case .interactionRequired, .userInteractionCancelled, .authenticationFailed, .failed:
            false
        }
    }

    static func failureState(for error: Error) -> SecureStorageIdentityMigrationRecordState {
        switch error {
        case KeychainService.KeychainError.interactionNotAllowed:
            .interactionRequired
        case KeychainService.KeychainError.userInteractionCancelled:
            .userInteractionCancelled
        case KeychainService.KeychainError.authenticationFailed:
            .authenticationFailed
        default:
            .failed
        }
    }
}

struct SecureStorageIdentityMigrationRecord: Equatable, Identifiable {
    let account: SecureStorageAccount
    let state: SecureStorageIdentityMigrationRecordState

    var id: String {
        account.identifier
    }
}

enum SecureStorageIdentityMigrationStage: String, Equatable {
    case journalLoad = "journal-load"
    case journalValidation = "journal-validation"
    case sourcePreflight = "source-preflight"
    case attemptIdentifier = "attempt-identifier"
    case journalCreate = "journal-create"
    case bridgeOpen = "bridge-open"
    case bridgePreflight = "bridge-preflight"
    case bridgeReconcile = "bridge-reconcile"
    case bridgeVerify = "bridge-verify"
    case bridgeManifestPersist = "bridge-manifest-persist"
    case journalCommit = "journal-commit"
    case committedBridgeOpen = "committed-bridge-open"
    case committedBridgeVerify = "committed-bridge-verify"
    case ready
}

struct SecureStorageIdentityMigrationReport: Equatable {
    let records: [SecureStorageIdentityMigrationRecord]
    let bridgeReady: Bool
    let blockingState: SecureStorageIdentityMigrationRecordState?
    let stage: SecureStorageIdentityMigrationStage

    var blockedUpdateMessage: String? {
        guard !bridgeReady else { return nil }
        let states = records.map(\.state) + [blockingState].compactMap(\.self)
        if states.contains(.userInteractionCancelled) {
            return "Updates are paused because Keychain access was cancelled. Quit and reopen RepoPrompt CE to retry, then approve Keychain access if prompted. Your existing credentials were not deleted."
        }
        if states.contains(.authenticationFailed) {
            return "Updates are paused because Keychain authentication failed. Unlock your login Keychain, then quit and reopen RepoPrompt CE to retry. Your existing credentials were not deleted."
        }
        if states.contains(.interactionRequired) {
            return "Updates are paused because the login Keychain is locked or unavailable. Unlock it, then quit and reopen RepoPrompt CE to retry. Your existing credentials were not deleted."
        }
        return "Updates are paused because secure credential migration could not be verified. Quit and reopen RepoPrompt CE to retry. Your existing credentials were not deleted."
    }
}

struct SecureStorageIdentityMigrationManifest: Codable, Equatable {
    static let currentVersion = 2

    enum Status: String, Codable {
        case preparing
        case committed
    }

    let version: Int
    let status: Status
    let attemptIdentifier: String
    let catalogIdentifiers: [String]

    func changingStatus(to status: Status) -> SecureStorageIdentityMigrationManifest {
        SecureStorageIdentityMigrationManifest(
            version: version,
            status: status,
            attemptIdentifier: attemptIdentifier,
            catalogIdentifiers: catalogIdentifiers
        )
    }
}

protocol SecureStorageIdentityMigrationStateStore {
    func load() throws -> SecureStorageIdentityMigrationManifest?
    /// Creates the journal only when no journal item exists yet. A fresh attempt must
    /// never overwrite an existing journal written by another actor or launch.
    func create(_ manifest: SecureStorageIdentityMigrationManifest) throws
    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws
}

/// A Keychain item is the durable migration journal and authority. Production preparers
/// create it with the same validated dual-identity ACL as the bridge so the successor can
/// discover the committed bridge marker. Unlike preferences, another same-user process
/// cannot silently rewrite it without satisfying that Keychain ACL.
struct KeychainSecureStorageIdentityMigrationStateStore: SecureStorageIdentityMigrationStateStore {
    static let account = "RepoPromptIdentityMigrationStateV2"

    enum StoreError: Error {
        case invalidManifest
        case verificationFailed
    }

    private let store: SecureKeyValueStorageBackend
    private let accessMode = KeychainAccessMode.nonInteractive(reason: .launch)

    init(
        store: SecureKeyValueStorageBackend = KeychainService(
            serviceName: KeychainService.identityMigrationLegacyStateServiceName
        )
    ) {
        self.store = store
    }

    func load() throws -> SecureStorageIdentityMigrationManifest? {
        let value: String
        do {
            value = try store.get(for: Self.account, accessMode: accessMode)
        } catch KeychainService.KeychainError.itemNotFound {
            return nil
        }
        guard let data = value.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(SecureStorageIdentityMigrationManifest.self, from: data)
        else {
            throw StoreError.invalidManifest
        }
        return manifest
    }

    func create(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        let value = try encodedManifestValue(manifest)
        try store.create(value, for: Self.account, accessMode: accessMode)
        try verifyPersistedValue(value)
    }

    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        let value = try encodedManifestValue(manifest)
        try store.save(value, for: Self.account, accessMode: accessMode)
        try verifyPersistedValue(value)
    }

    private func encodedManifestValue(_ manifest: SecureStorageIdentityMigrationManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidManifest
        }
        return value
    }

    private func verifyPersistedValue(_ value: String) throws {
        guard try store.get(for: Self.account, accessMode: accessMode) == value else {
            throw StoreError.verificationFailed
        }
    }
}

/// Copies the closed secure-storage inventory into a new service whose item ACL trusts
/// both signing identities. A legacy-Keychain journal is committed before mutation, so
/// interrupted attempts can reconcile only items in that attempt's random service.
final class SecureStorageIdentityMigrationCoordinator {
    typealias BridgeStoreFactory = (String) throws -> SecureKeyValueStorageBackend
    typealias AttemptIdentifierGenerator = () -> String

    private enum CoordinatorError: Error {
        case manifestEncodingFailed
        case manifestConflict
        case manifestVerificationFailed
    }

    static let bridgeManifestAccount = "RepoPromptIdentityMigrationBridgeManifestV2"

    private let accounts: [SecureStorageAccount]
    private let sourceStore: SecureKeyValueStorageBackend
    private let bridgeStoreFactory: BridgeStoreFactory
    private let stateStore: SecureStorageIdentityMigrationStateStore
    private let attemptIdentifierGenerator: AttemptIdentifierGenerator
    private let accessMode = KeychainAccessMode.nonInteractive(reason: .launch)

    init(
        accounts: [SecureStorageAccount] = SecureStorageAccountCatalog.identityMigrationV2Accounts,
        sourceStore: SecureKeyValueStorageBackend,
        bridgeStoreFactory: @escaping BridgeStoreFactory,
        stateStore: SecureStorageIdentityMigrationStateStore,
        attemptIdentifierGenerator: @escaping AttemptIdentifierGenerator = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.accounts = accounts
        self.sourceStore = sourceStore
        self.bridgeStoreFactory = bridgeStoreFactory
        self.stateStore = stateStore
        self.attemptIdentifierGenerator = attemptIdentifierGenerator
    }

    func prepareBridge() -> SecureStorageIdentityMigrationReport {
        let existingManifest: SecureStorageIdentityMigrationManifest?
        do {
            existingManifest = try stateStore.load()
        } catch {
            // An unreadable or undecodable journal is an authority failure. After a bridge
            // has been committed, the journal is the only pointer to it, so destructive
            // reset-and-retry could silently restart migration from stale source data.
            // Fail closed and keep the journal item intact for manual recovery.
            return blockedReport(error: error, stage: .journalLoad)
        }

        if let existingManifest {
            guard isStructurallyValid(existingManifest) else {
                return blockedReport(stage: .journalValidation)
            }
            switch existingManifest.status {
            case .preparing:
                return resumePreparation(existingManifest)
            case .committed:
                return verifyCommittedBridge(existingManifest)
            }
        }

        let sourceResults = readAll(from: sourceStore)
        let preflightRecords = recordsForReadFailures(sourceResults)
        guard preflightRecords.allSatisfy(\.state.isReady) else {
            return failedReport(records: preflightRecords, stage: .sourcePreflight)
        }

        let attemptIdentifier = attemptIdentifierGenerator()
        guard KeychainService.identityMigrationBridgeServiceName(for: attemptIdentifier) != nil else {
            return failedReport(
                records: preflightRecords,
                error: KeychainACLValidationError.invalidExpectedPrincipalPolicy,
                stage: .attemptIdentifier
            )
        }
        let manifest = SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: .preparing,
            attemptIdentifier: attemptIdentifier,
            catalogIdentifiers: expectedCatalogIdentifiers
        )
        do {
            try stateStore.create(manifest)
        } catch {
            return failedReport(records: preflightRecords, error: error, stage: .journalCreate)
        }
        return resumePreparation(manifest, sourceResults: sourceResults)
    }

    private struct ReadResult {
        let value: String?
        let failureState: SecureStorageIdentityMigrationRecordState?
    }

    private var expectedCatalogIdentifiers: [String] {
        accounts.map(\.identifier).sorted()
    }

    private func isStructurallyValid(_ manifest: SecureStorageIdentityMigrationManifest) -> Bool {
        Self.isStructurallyValid(
            manifest,
            expectedCatalogIdentifiers: expectedCatalogIdentifiers
        )
    }

    static func isStructurallyValid(
        _ manifest: SecureStorageIdentityMigrationManifest,
        expectedCatalogIdentifiers: [String]
    ) -> Bool {
        manifest.version == SecureStorageIdentityMigrationManifest.currentVersion
            && KeychainService.identityMigrationBridgeServiceName(for: manifest.attemptIdentifier) != nil
            && manifest.catalogIdentifiers == expectedCatalogIdentifiers.sorted()
    }

    private func readAll(from store: SecureKeyValueStorageBackend) -> [SecureStorageAccount: ReadResult] {
        Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account, read(account.identifier, from: store))
        })
    }

    private func read(_ key: String, from store: SecureKeyValueStorageBackend) -> ReadResult {
        do {
            return try ReadResult(
                value: store.get(for: key, accessMode: accessMode),
                failureState: nil
            )
        } catch KeychainService.KeychainError.itemNotFound {
            return ReadResult(value: nil, failureState: nil)
        } catch KeychainService.KeychainError.interactionNotAllowed {
            return ReadResult(value: nil, failureState: .interactionRequired)
        } catch KeychainService.KeychainError.userInteractionCancelled {
            return ReadResult(value: nil, failureState: .userInteractionCancelled)
        } catch KeychainService.KeychainError.authenticationFailed {
            return ReadResult(value: nil, failureState: .authenticationFailed)
        } catch {
            return ReadResult(value: nil, failureState: .failed)
        }
    }

    private func recordsForReadFailures(
        _ results: [SecureStorageAccount: ReadResult]
    ) -> [SecureStorageIdentityMigrationRecord] {
        accounts.map { account in
            let result = results[account]
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: result?.failureState ?? (result?.value == nil ? .absent : .verified)
            )
        }
    }

    private func resumePreparation(
        _ manifest: SecureStorageIdentityMigrationManifest,
        sourceResults suppliedSourceResults: [SecureStorageAccount: ReadResult]? = nil
    ) -> SecureStorageIdentityMigrationReport {
        let bridgeStore: SecureKeyValueStorageBackend
        do {
            bridgeStore = try bridgeStoreFactory(manifest.attemptIdentifier)
        } catch {
            return blockedReport(error: error, stage: .bridgeOpen)
        }
        let sourceResults = suppliedSourceResults ?? readAll(from: sourceStore)
        let bridgeResults = readAll(from: bridgeStore)
        let preflightRecords = zipResults(source: sourceResults, bridge: bridgeResults)
        guard preflightRecords.allSatisfy(\.state.isReady) else {
            return failedReport(records: preflightRecords, stage: .bridgePreflight)
        }

        var records: [SecureStorageIdentityMigrationRecord] = []
        for account in accounts {
            guard let source = sourceResults[account], let bridge = bridgeResults[account] else {
                records.append(SecureStorageIdentityMigrationRecord(account: account, state: .failed))
                continue
            }
            records.append(reconcile(account, source: source, bridge: bridge, bridgeStore: bridgeStore))
        }
        guard records.allSatisfy(\.state.isReady) else {
            return failedReport(records: records, stage: .bridgeReconcile)
        }

        if let verificationFailure = verifyValuesMatch(bridgeStore: bridgeStore) {
            return failedReport(
                records: records,
                blockingState: verificationFailure,
                stage: .bridgeVerify
            )
        }

        let committedManifest = manifest.changingStatus(to: .committed)
        do {
            try persistBridgeManifest(committedManifest, bridgeStore: bridgeStore)
        } catch {
            return failedReport(
                records: records,
                error: error,
                stage: .bridgeManifestPersist
            )
        }
        do {
            try stateStore.save(committedManifest)
        } catch {
            return failedReport(records: records, error: error, stage: .journalCommit)
        }
        return SecureStorageIdentityMigrationReport(
            records: records,
            bridgeReady: true,
            blockingState: nil,
            stage: .ready
        )
    }

    private func zipResults(
        source: [SecureStorageAccount: ReadResult],
        bridge: [SecureStorageAccount: ReadResult]
    ) -> [SecureStorageIdentityMigrationRecord] {
        accounts.map { account in
            let failure = source[account]?.failureState ?? bridge[account]?.failureState
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: failure ?? .verified
            )
        }
    }

    private func reconcile(
        _ account: SecureStorageAccount,
        source: ReadResult,
        bridge: ReadResult,
        bridgeStore: SecureKeyValueStorageBackend
    ) -> SecureStorageIdentityMigrationRecord {
        guard source.failureState == nil, bridge.failureState == nil else {
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: source.failureState ?? bridge.failureState ?? .failed
            )
        }

        do {
            switch (source.value, bridge.value) {
            case (nil, nil):
                return SecureStorageIdentityMigrationRecord(account: account, state: .absent)
            case let (sourceValue?, nil):
                try bridgeStore.create(sourceValue, for: account.identifier, accessMode: accessMode)
                let verified = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                return SecureStorageIdentityMigrationRecord(
                    account: account,
                    state: verified == sourceValue ? .copied : .failed
                )
            case let (sourceValue?, bridgeValue?):
                if sourceValue == bridgeValue {
                    return SecureStorageIdentityMigrationRecord(account: account, state: .verified)
                }
                // The random attempt-specific service and preparing journal prove
                // this is an interrupted attempt. The source remains authoritative
                // until commit.
                try bridgeStore.save(sourceValue, for: account.identifier, accessMode: accessMode)
                let verified = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                return SecureStorageIdentityMigrationRecord(
                    account: account,
                    state: verified == sourceValue ? .copied : .failed
                )
            case (nil, _?):
                try bridgeStore.delete(for: account.identifier, accessMode: accessMode)
                do {
                    _ = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                    return SecureStorageIdentityMigrationRecord(account: account, state: .failed)
                } catch KeychainService.KeychainError.itemNotFound {
                    return SecureStorageIdentityMigrationRecord(account: account, state: .absent)
                }
            }
        } catch {
            return SecureStorageIdentityMigrationRecord(
                account: account,
                state: SecureStorageIdentityMigrationRecordState.failureState(for: error)
            )
        }
    }

    private func verifyValuesMatch(
        bridgeStore: SecureKeyValueStorageBackend
    ) -> SecureStorageIdentityMigrationRecordState? {
        let sourceResults = readAll(from: sourceStore)
        let bridgeResults = readAll(from: bridgeStore)
        for account in accounts {
            guard let source = sourceResults[account],
                  let bridge = bridgeResults[account]
            else {
                return .failed
            }
            if let failureState = source.failureState ?? bridge.failureState {
                return failureState
            }
            guard source.value == bridge.value else { return .failed }
        }
        return nil
    }

    private func persistBridgeManifest(
        _ manifest: SecureStorageIdentityMigrationManifest,
        bridgeStore: SecureKeyValueStorageBackend
    ) throws {
        guard let encoded = Self.encodeManifest(manifest) else {
            throw CoordinatorError.manifestEncodingFailed
        }
        let existingValue: String?
        do {
            existingValue = try bridgeStore.get(for: Self.bridgeManifestAccount, accessMode: accessMode)
        } catch KeychainService.KeychainError.itemNotFound {
            existingValue = nil
        }
        if let existingValue {
            guard existingValue == encoded else { throw CoordinatorError.manifestConflict }
        } else {
            try bridgeStore.create(encoded, for: Self.bridgeManifestAccount, accessMode: accessMode)
        }
        guard try bridgeStore.get(
            for: Self.bridgeManifestAccount,
            accessMode: accessMode
        ) == encoded else {
            throw CoordinatorError.manifestVerificationFailed
        }
    }

    private func verifyCommittedBridge(
        _ manifest: SecureStorageIdentityMigrationManifest
    ) -> SecureStorageIdentityMigrationReport {
        let bridgeStore: SecureKeyValueStorageBackend
        do {
            bridgeStore = try bridgeStoreFactory(manifest.attemptIdentifier)
        } catch {
            return blockedReport(error: error, stage: .committedBridgeOpen)
        }
        let records: [SecureStorageIdentityMigrationRecord]
        do {
            records = try SecureStorageIdentityMigrationCommittedProjection.verify(
                manifest: manifest,
                accounts: accounts,
                bridgeStore: bridgeStore,
                accessMode: accessMode
            )
        } catch {
            return blockedReport(error: error, stage: .committedBridgeVerify)
        }
        return SecureStorageIdentityMigrationReport(
            records: records,
            bridgeReady: true,
            blockingState: nil,
            stage: .ready
        )
    }

    static func encodeManifest(_ manifest: SecureStorageIdentityMigrationManifest) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func failedReport(
        records: [SecureStorageIdentityMigrationRecord],
        error: Error? = nil,
        blockingState: SecureStorageIdentityMigrationRecordState? = nil,
        stage: SecureStorageIdentityMigrationStage
    ) -> SecureStorageIdentityMigrationReport {
        SecureStorageIdentityMigrationReport(
            records: records,
            bridgeReady: false,
            blockingState: error.map {
                SecureStorageIdentityMigrationRecordState.failureState(for: $0)
            } ?? blockingState,
            stage: stage
        )
    }

    private func blockedReport(
        error: Error? = nil,
        stage: SecureStorageIdentityMigrationStage
    ) -> SecureStorageIdentityMigrationReport {
        failedReport(records: [], error: error, stage: stage)
    }
}

enum SecureStorageIdentityMigrationActivationError: Error {
    case invalidJournal
    case invalidBridgeManifest
}

/// Shared verification of a committed bridge's full projection under the frozen
/// version-2 manifest contract, expressed in the existing record states:
/// - the journal manifest must be committed and must cover exactly the expected
///   account catalog;
/// - the bridge-manifest item must equal the committed journal encoding
///   byte-for-byte -- any other present value (a mismatched attempt or a planted
///   preparing manifest) is rejected as an invalid bridge manifest;
/// - every cataloged account resolves to an explicit record state: a readable
///   value is `.verified` (readability is the strongest value contract the frozen
///   digest-free schema allows), a missing item is `.absent`, and any other read
///   failure propagates so callers surface its specific blocked reason instead of
///   silently accepting an unreadable projection.
enum SecureStorageIdentityMigrationCommittedProjection {
    static func verify(
        manifest: SecureStorageIdentityMigrationManifest,
        accounts: [SecureStorageAccount],
        bridgeStore: SecureKeyValueStorageBackend,
        accessMode: KeychainAccessMode
    ) throws -> [SecureStorageIdentityMigrationRecord] {
        guard manifest.status == .committed,
              manifest.catalogIdentifiers == accounts.map(\.identifier).sorted(),
              let encoded = SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest)
        else {
            throw SecureStorageIdentityMigrationActivationError.invalidJournal
        }
        guard try bridgeStore.get(
            for: SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount,
            accessMode: accessMode
        ) == encoded else {
            throw SecureStorageIdentityMigrationActivationError.invalidBridgeManifest
        }
        return try accounts.map { account in
            do {
                _ = try bridgeStore.get(for: account.identifier, accessMode: accessMode)
                return SecureStorageIdentityMigrationRecord(account: account, state: .verified)
            } catch KeychainService.KeychainError.itemNotFound {
                return SecureStorageIdentityMigrationRecord(account: account, state: .absent)
            }
        }
    }
}

struct SecureStorageIdentityMigrationCommittedBridge {
    let manifest: SecureStorageIdentityMigrationManifest
    let store: SecureKeyValueStorageBackend
}

/// Resolves the committed bridge from authenticated storage. Production stores
/// validate each item's decrypt ACL before returning its JSON, so structural
/// equality is only considered after the journal and bridge-manifest authorities
/// have both been proven.
struct SecureStorageIdentityMigrationCommittedBridgeResolver {
    let accounts: [SecureStorageAccount]
    let stateStore: SecureStorageIdentityMigrationStateStore
    let bridgeStoreFactory: SecureStorageIdentityMigrationCoordinator.BridgeStoreFactory

    func resolve() throws -> SecureStorageIdentityMigrationCommittedBridge? {
        guard let manifest = try stateStore.load() else { return nil }
        guard manifest.status == .committed,
              SecureStorageIdentityMigrationCoordinator.isStructurallyValid(
                  manifest,
                  expectedCatalogIdentifiers: accounts.map(\.identifier)
              )
        else {
            throw SecureStorageIdentityMigrationActivationError.invalidJournal
        }

        let bridgeStore = try bridgeStoreFactory(manifest.attemptIdentifier)
        _ = try SecureStorageIdentityMigrationCommittedProjection.verify(
            manifest: manifest,
            accounts: accounts,
            bridgeStore: bridgeStore,
            accessMode: .nonInteractive(reason: .launch)
        )
        return SecureStorageIdentityMigrationCommittedBridge(
            manifest: manifest,
            store: bridgeStore
        )
    }
}

final class IdentityMigrationRuntimeState: @unchecked Sendable {
    static let shared = IdentityMigrationRuntimeState()

    private let lock = NSLock()
    private var blockedMessage: String?

    func setBlockedMessage(_ message: String?) {
        lock.lock()
        blockedMessage = message
        lock.unlock()
    }

    func updatesBlockedMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return blockedMessage
    }
}

enum SecureStorageIdentityMigrationBootstrap {
    static let phaseInfoKey = "RepoPromptIdentityMigrationPhase"
    static let anchorRelativePathInfoKey = "RepoPromptIdentityMigrationAnchorRelativePath"

    enum Phase: String {
        case disabled
        case legacyPreparer = "legacy-preparer"
    }

    static let unrecognizedConfigurationMessage =
        "Updates are paused because this build has an unrecognized secure credential migration configuration."
    static let successorUnsupportedPhaseMessage =
        "Updates are paused because this build has an unsupported secure credential migration configuration."
    static let successorMissingBridgeMessage =
        "Updates are paused because this Mac's credentials have not finished migrating from the previous RepoPrompt CE version. Open the previous RepoPrompt CE version to complete credential migration, then relaunch this app. Your existing credentials were not deleted."

    /// Pure phase gate for a successor-identity launch. Returns nil when bridge
    /// activation may proceed, or the stable blocked guidance otherwise.
    static func successorBlockedMessage(forPhase phase: Phase?) -> String? {
        switch phase {
        case .disabled:
            nil
        case .legacyPreparer:
            successorUnsupportedPhaseMessage
        case nil:
            unrecognizedConfigurationMessage
        }
    }

    static func configuredPhase(from value: Any?) -> Phase? {
        guard let rawPhase = value as? String else { return nil }
        return Phase(rawValue: rawPhase)
    }

    static func preparerCatalogMatchesFrozenCatalog(
        currentAccounts: [SecureStorageAccount] = SecureStorageAccountCatalog.allAccounts,
        migrationAccounts: [SecureStorageAccount] = SecureStorageAccountCatalog.identityMigrationV2Accounts
    ) -> Bool {
        currentAccounts.map(\.identifier) == migrationAccounts.map(\.identifier)
    }

    static func prepareIfConfigured(bundle: Bundle = .main) {
        IdentityMigrationRuntimeState.shared.setBlockedMessage(nil)
        let domain = SecureKeyValueStorageFactory.currentDecision().domain
        let phase = configuredPhase(from: bundle.object(forInfoDictionaryKey: phaseInfoKey))
        switch domain {
        case .officialDeveloperID:
            recordDiagnostic(
                stage: "bootstrap",
                outcome: .started,
                bundle: bundle,
                domain: domain
            )
            guard let phase else {
                recordDiagnostic(
                    stage: "configuration",
                    outcome: .blocked,
                    bundle: bundle,
                    domain: domain
                )
                blockUpdates(unrecognizedConfigurationMessage)
                return
            }
            switch phase {
            case .disabled:
                activateCommittedBridgeIfPresent(bridgeRequired: false, bundle: bundle)
            case .legacyPreparer:
                prepareLegacyBridge(bundle: bundle)
            }
        case .successorOfficialDeveloperID:
            recordDiagnostic(
                stage: "bootstrap",
                outcome: .started,
                bundle: bundle,
                domain: domain
            )
            if let blockedMessage = successorBlockedMessage(forPhase: phase) {
                recordDiagnostic(
                    stage: "configuration",
                    outcome: .blocked,
                    bundle: bundle,
                    domain: domain
                )
                blockUpdates(blockedMessage)
                return
            }
            // The successor identity has no legacy storage fallback: without an
            // authenticated committed bridge it must stay ephemeral and say so.
            activateCommittedBridgeIfPresent(bridgeRequired: true, bundle: bundle)
        case .localSelfSigned, .appleDevelopmentDebug, .ephemeral:
            return
        }
    }

    private static func prepareLegacyBridge(bundle: Bundle) {
        guard preparerCatalogMatchesFrozenCatalog(),
              bundle.bundleIdentifier == RuntimeCodeSigningPolicy.developerIDBundleIdentifier,
              let executableURL = bundle.executableURL,
              let resourceURL = bundle.resourceURL,
              let relativeAnchorPath = bundle.object(forInfoDictionaryKey: anchorRelativePathInfoKey) as? String,
              !relativeAnchorPath.isEmpty,
              let anchorURL = validatedAnchorURL(relativePath: relativeAnchorPath, resourceURL: resourceURL),
              RuntimeCodeSigningDetector.validatesStaticCode(
                  at: bundle.bundleURL,
                  requirementSource: RuntimeCodeSigningPolicy.developerIDRequirement
              ),
              RuntimeCodeSigningDetector.validatesStaticCode(
                  at: anchorURL,
                  requirementSource: RuntimeCodeSigningPolicy.successorDeveloperIDRequirement
              )
        else {
            recordDiagnostic(
                stage: "preparer-validation",
                outcome: .blocked,
                bundle: bundle,
                domain: .officialDeveloperID
            )
            blockUpdates("Updates are paused because the secure credential migration package is incomplete, its account catalog changed, or it has an invalid identity anchor.")
            return
        }

        let authority: KeychainAccessAuthority
        do {
            authority = try KeychainAccessAuthority(
                descriptor: "RepoPrompt CE identity migration bridge",
                applications: [
                    TrustedApplicationCodeRequirement(
                        trustedApplicationPath: executableURL.path,
                        codeURL: bundle.bundleURL,
                        requirementSource: RuntimeCodeSigningPolicy.developerIDRequirement
                    ),
                    TrustedApplicationCodeRequirement(
                        trustedApplicationPath: anchorURL.path,
                        codeURL: anchorURL,
                        requirementSource: RuntimeCodeSigningPolicy.successorDeveloperIDRequirement
                    )
                ]
            )
        } catch {
            recordDiagnostic(
                stage: "preparer-authority",
                outcome: .blocked,
                bundle: bundle,
                domain: .officialDeveloperID,
                error: error
            )
            blockUpdates(for: error)
            return
        }
        let attributeProvider = authority.creationAttributeProvider
        let stateStore = KeychainSecureStorageIdentityMigrationStateStore(
            store: KeychainService(
                serviceName: KeychainService.identityMigrationLegacyStateServiceName,
                itemCreationAttributeProvider: attributeProvider,
                itemAccessValidator: authority.accessValidator
            )
        )
        let coordinator = SecureStorageIdentityMigrationCoordinator(
            sourceStore: KeychainService.officialV2Shared,
            bridgeStoreFactory: { attemptIdentifier in
                try bridgeStore(
                    attemptIdentifier: attemptIdentifier,
                    itemCreationAttributeProvider: attributeProvider,
                    itemAccessValidator: authority.accessValidator
                )
            },
            stateStore: stateStore
        )
        let report = coordinator.prepareBridge()
        recordDiagnostic(
            stage: report.stage.rawValue,
            outcome: report.bridgeReady ? .succeeded : .blocked,
            bundle: bundle,
            domain: .officialDeveloperID,
            recordStateCounts: report.diagnosticStateCounts
        )
        guard report.bridgeReady else {
            blockUpdates(report.blockedUpdateMessage)
            return
        }
        let manifest: SecureStorageIdentityMigrationManifest
        do {
            guard let loadedManifest = try stateStore.load(),
                  loadedManifest.status == .committed
            else {
                recordDiagnostic(
                    stage: "post-commit-journal-load",
                    outcome: .blocked,
                    bundle: bundle,
                    domain: .officialDeveloperID
                )
                blockUpdates("Updates are paused because the secure credential migration journal is incomplete.")
                return
            }
            manifest = loadedManifest
        } catch {
            recordDiagnostic(
                stage: "post-commit-journal-load",
                outcome: .blocked,
                bundle: bundle,
                domain: .officialDeveloperID,
                error: error
            )
            blockUpdates(for: error)
            return
        }

        do {
            let bridge = try bridgeStore(
                attemptIdentifier: manifest.attemptIdentifier,
                itemCreationAttributeProvider: attributeProvider,
                itemAccessValidator: authority.accessValidator
            )
            SecureKeyValueStorageFactory.installOfficialBackendOverride(bridge)
            recordDiagnostic(
                stage: "preparer-activation",
                outcome: .succeeded,
                bundle: bundle,
                domain: .officialDeveloperID
            )
        } catch {
            recordDiagnostic(
                stage: "preparer-activation",
                outcome: .blocked,
                bundle: bundle,
                domain: .officialDeveloperID,
                error: error
            )
            blockUpdates(for: error)
        }
    }

    private static func activateCommittedBridgeIfPresent(
        bridgeRequired: Bool,
        bundle: Bundle
    ) {
        let domain: RuntimeSecureStorageDomain = bridgeRequired
            ? .successorOfficialDeveloperID
            : .officialDeveloperID
        let accessValidator: ClassicKeychainACLValidator
        do {
            accessValidator = try ClassicKeychainACLValidator(
                requirementSources: [
                    RuntimeCodeSigningPolicy.developerIDRequirement,
                    RuntimeCodeSigningPolicy.successorDeveloperIDRequirement
                ]
            )
        } catch {
            recordDiagnostic(
                stage: "activation-authority",
                outcome: .blocked,
                bundle: bundle,
                domain: domain,
                error: error
            )
            blockUpdates(for: error)
            return
        }
        let stateStore = KeychainSecureStorageIdentityMigrationStateStore(
            store: KeychainService(
                serviceName: KeychainService.identityMigrationLegacyStateServiceName,
                itemAccessValidator: accessValidator
            )
        )
        let resolution: SecureStorageIdentityMigrationCommittedBridge?
        do {
            resolution = try SecureStorageIdentityMigrationCommittedBridgeResolver(
                accounts: SecureStorageAccountCatalog.identityMigrationV2Accounts,
                stateStore: stateStore,
                bridgeStoreFactory: { attemptIdentifier in
                    guard let serviceName = KeychainService.identityMigrationBridgeServiceName(
                        for: attemptIdentifier
                    ) else {
                        throw SecureStorageIdentityMigrationActivationError.invalidJournal
                    }
                    return KeychainService(
                        serviceName: serviceName,
                        itemAccessValidator: accessValidator
                    )
                }
            ).resolve()
        } catch {
            recordDiagnostic(
                stage: "committed-bridge-resolve",
                outcome: .blocked,
                bundle: bundle,
                domain: domain,
                error: error
            )
            blockUpdates(for: error)
            return
        }
        guard let resolution else {
            recordDiagnostic(
                stage: "committed-bridge-resolve",
                outcome: bridgeRequired ? .blocked : .skipped,
                bundle: bundle,
                domain: domain
            )
            if bridgeRequired {
                blockUpdates(successorMissingBridgeMessage)
            }
            return
        }
        let manifest = resolution.manifest

        guard let bridgeServiceName = KeychainService.identityMigrationBridgeServiceName(
            for: manifest.attemptIdentifier
        ) else {
            recordDiagnostic(
                stage: "committed-bridge-service",
                outcome: .blocked,
                bundle: bundle,
                domain: domain
            )
            blockUpdates("Updates are paused because the secure credential migration journal is incomplete.")
            return
        }

        let accessProvider = ExistingKeychainItemAccessAttributeProvider(
            serviceName: bridgeServiceName,
            account: SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount,
            accessValidator: accessValidator
        )
        do {
            let bridge = try bridgeStore(
                attemptIdentifier: manifest.attemptIdentifier,
                itemCreationAttributeProvider: accessProvider,
                itemAccessValidator: accessValidator
            )
            SecureKeyValueStorageFactory.installOfficialBackendOverride(bridge)
            recordDiagnostic(
                stage: "committed-bridge-activation",
                outcome: .succeeded,
                bundle: bundle,
                domain: domain
            )
        } catch {
            recordDiagnostic(
                stage: "committed-bridge-activation",
                outcome: .blocked,
                bundle: bundle,
                domain: domain,
                error: error
            )
            blockUpdates(for: error)
        }
    }

    private static func bridgeStore(
        attemptIdentifier: String,
        itemCreationAttributeProvider: KeychainItemCreationAttributeProvider,
        itemAccessValidator: KeychainItemAccessValidator
    ) throws -> KeychainService {
        guard let serviceName = KeychainService.identityMigrationBridgeServiceName(for: attemptIdentifier) else {
            throw KeychainACLValidationError.invalidExpectedPrincipalPolicy
        }
        return KeychainService(
            serviceName: serviceName,
            itemCreationAttributeProvider: itemCreationAttributeProvider,
            itemAccessValidator: itemAccessValidator
        )
    }

    static func validatedAnchorURL(relativePath: String, resourceURL: URL) -> URL? {
        let resolvedResources = resourceURL.resolvingSymlinksInPath().standardizedFileURL
        let unresolvedCandidate = resolvedResources
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let resolvedCandidate = unresolvedCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard unresolvedCandidate.path.hasPrefix(resolvedResources.path + "/"),
              resolvedCandidate == unresolvedCandidate,
              let values = try? unresolvedCandidate.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
                  .isExecutableKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isExecutable == true
        else {
            return nil
        }
        return unresolvedCandidate
    }

    private static func blockUpdates(_ message: String?) {
        IdentityMigrationRuntimeState.shared.setBlockedMessage(
            message ?? "Updates are paused because secure credential migration could not be verified."
        )
    }

    private static func blockUpdates(for error: Error) {
        let report = SecureStorageIdentityMigrationReport(
            records: [],
            bridgeReady: false,
            blockingState: SecureStorageIdentityMigrationRecordState.failureState(for: error),
            stage: .committedBridgeVerify
        )
        blockUpdates(report.blockedUpdateMessage)
    }

    private static func recordDiagnostic(
        stage: String,
        outcome: IdentityTransitionDiagnosticEvent.Outcome,
        bundle: Bundle,
        domain: RuntimeSecureStorageDomain,
        recordStateCounts: [String: Int]? = nil,
        error: Error? = nil
    ) {
        IdentityTransitionDiagnostics.shared.record(
            subsystem: .secureStorage,
            stage: stage,
            outcome: outcome,
            bundle: bundle,
            secureStorageDomain: domain,
            recordStateCounts: recordStateCounts,
            errorClass: error.map(diagnosticErrorClass)
        )
    }

    private static func diagnosticErrorClass(_ error: Error) -> String {
        switch SecureStorageIdentityMigrationRecordState.failureState(for: error) {
        case .interactionRequired: "interaction-required"
        case .userInteractionCancelled: "cancelled"
        case .authenticationFailed: "authentication-failed"
        case .absent, .copied, .verified, .failed: "other"
        }
    }
}

private extension SecureStorageIdentityMigrationReport {
    var diagnosticStateCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for record in records {
            counts[record.state.diagnosticName, default: 0] += 1
        }
        if let blockingState {
            counts["blocking-\(blockingState.diagnosticName)", default: 0] += 1
        }
        return counts
    }
}

private extension SecureStorageIdentityMigrationRecordState {
    var diagnosticName: String {
        switch self {
        case .absent: "absent"
        case .copied: "copied"
        case .verified: "verified"
        case .interactionRequired: "interaction-required"
        case .userInteractionCancelled: "cancelled"
        case .authenticationFailed: "authentication-failed"
        case .failed: "failed"
        }
    }
}
