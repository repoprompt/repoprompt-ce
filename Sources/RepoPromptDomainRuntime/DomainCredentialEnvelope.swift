import Foundation

package struct DomainCredentialScope: Codable, Hashable, Sendable {
    package let providerIdentifier: String
    package let runID: UUID
    package let launchID: UUID?
    package let oracleGroupID: OracleGroupID?
    package let oracleLaneID: OracleLaneID?
    package let oracleGroupClaimID: UUID?
    package let principalID: UUID
    package let purpose: String
    package let accountIdentifierDigest: String?

    package init(
        providerIdentifier: String,
        runID: UUID,
        launchID: UUID? = nil,
        oracleGroupID: OracleGroupID? = nil,
        oracleLaneID: OracleLaneID? = nil,
        oracleGroupClaimID: UUID? = nil,
        principalID: UUID,
        purpose: String,
        accountIdentifierDigest: String? = nil
    ) {
        self.providerIdentifier = providerIdentifier
        self.runID = runID
        self.launchID = launchID
        self.oracleGroupID = oracleGroupID
        self.oracleLaneID = oracleLaneID
        self.oracleGroupClaimID = oracleGroupClaimID
        self.principalID = principalID
        self.purpose = purpose
        self.accountIdentifierDigest = accountIdentifierDigest
    }
}

package struct DomainCredentialEnvelopeDescriptor: Hashable, Sendable {
    package let envelopeID: UUID
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let scope: DomainCredentialScope
    package let expiresAt: ContinuousClock.Instant

    package init(
        envelopeID: UUID,
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        scope: DomainCredentialScope,
        expiresAt: ContinuousClock.Instant
    ) {
        self.envelopeID = envelopeID
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.scope = scope
        self.expiresAt = expiresAt
    }
}

package enum DomainCredentialPayloadError: Error, Equatable, Sendable {
    case alreadyConsumed
}

private final class DomainSecureCredentialBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: UnsafeMutableRawPointer
    let byteCount: Int
    private var isZeroed = false

    init(bytes: [UInt8]) {
        precondition(!bytes.isEmpty)
        byteCount = bytes.count
        storage = UnsafeMutableRawPointer.allocate(
            byteCount: bytes.count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        bytes.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return }
            storage.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
    }

    private init(copying source: UnsafeRawPointer, byteCount: Int) {
        self.byteCount = byteCount
        storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        storage.copyMemory(from: source, byteCount: byteCount)
    }

    deinit {
        lock.lock()
        zeroLocked()
        lock.unlock()
        storage.deallocate()
    }

    func clone() throws -> DomainSecureCredentialBuffer {
        lock.lock()
        defer { lock.unlock() }
        guard !isZeroed else { throw DomainCredentialPayloadError.alreadyConsumed }
        return DomainSecureCredentialBuffer(copying: UnsafeRawPointer(storage), byteCount: byteCount)
    }

    func consume<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        lock.lock()
        defer {
            zeroLocked()
            lock.unlock()
        }
        guard !isZeroed else { throw DomainCredentialPayloadError.alreadyConsumed }
        return try body(UnsafeRawBufferPointer(start: storage, count: byteCount))
    }

    func zeroInPlace() {
        lock.lock()
        zeroLocked()
        lock.unlock()
    }

    private func zeroLocked() {
        guard !isZeroed else { return }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        isZeroed = true
    }

    #if DEBUG
        func testSnapshot() -> [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            let bytes = storage.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: byteCount))
        }

        func testIsZeroed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isZeroed else { return false }
            let bytes = storage.assumingMemoryBound(to: UInt8.self)
            return UnsafeBufferPointer(start: bytes, count: byteCount).allSatisfy { $0 == 0 }
        }
    #endif
}

package final class DomainCredentialPayload: @unchecked Sendable, CustomStringConvertible {
    private let storage: DomainSecureCredentialBuffer
    private let originalByteCount: Int
    private let expiresAt: ContinuousClock.Instant
    private let lifetimeLock = NSLock()
    private var expiryTask: Task<Void, Never>?

    fileprivate init(
        storage: DomainSecureCredentialBuffer,
        expiresAt: ContinuousClock.Instant
    ) {
        self.storage = storage
        originalByteCount = storage.byteCount
        self.expiresAt = expiresAt
        let taskStorage = storage
        expiryTask = Task {
            do {
                try await ContinuousClock().sleep(until: expiresAt)
            } catch {
                return
            }
            taskStorage.zeroInPlace()
        }
    }

    deinit {
        revoke()
        storage.zeroInPlace()
    }

    package func withConsumedBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) throws -> Result {
        defer { revoke() }
        return try storage.consume(body)
    }

    private func revoke() {
        lifetimeLock.lock()
        let task = expiryTask
        expiryTask = nil
        lifetimeLock.unlock()
        task?.cancel()
    }

    package var description: String {
        "<redacted credential payload: \(originalByteCount) bytes>"
    }

    #if DEBUG
        package func test_ownedStorageBytes() -> [UInt8] {
            storage.testSnapshot()
        }

        package func test_isOwnedStorageZeroed() -> Bool {
            storage.testIsZeroed()
        }

        package func test_expiresAt() -> ContinuousClock.Instant {
            expiresAt
        }
    #endif
}

package enum DomainCredentialEnvelopeError: Error, Equatable, Sendable {
    case unavailable
    case payloadTooLarge
    case tooManyOutstandingEnvelopes
    case expired
    case alreadyConsumed
    case runtimeMismatch
    case scopeMismatch
    case revoked
}

package actor DomainCredentialEnvelopeStore {
    package static let maximumPayloadBytes = 64 * 1024
    package static let maximumOutstandingEnvelopeCount = 256
    package static let maximumTombstoneCount = 256

    private enum State: Sendable, Equatable {
        case active
        case consumed
        case expired
        case revoked
    }

    private struct Record: Sendable {
        let descriptor: DomainCredentialEnvelopeDescriptor
        var storage: DomainSecureCredentialBuffer?
        var state: State
    }

    private let identity: DomainRuntimeIdentity
    private let clock = ContinuousClock()
    private var records: [UUID: Record] = [:]
    private var terminalOrder: [UUID] = []
    private var activeEnvelopeCount = 0
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    package init(identity: DomainRuntimeIdentity) {
        self.identity = identity
    }

    package func issue(
        bytes: [UInt8],
        scope: DomainCredentialScope,
        lifetime: Duration = .seconds(60)
    ) throws -> DomainCredentialEnvelopeDescriptor {
        guard !isShuttingDown, !bytes.isEmpty else { throw DomainCredentialEnvelopeError.unavailable }
        let oracleIdentityCount = [
            scope.oracleGroupID != nil,
            scope.oracleLaneID != nil,
            scope.oracleGroupClaimID != nil,
        ].count(where: { $0 })
        guard oracleIdentityCount == 0 || (oracleIdentityCount == 3 && scope.launchID != nil) else {
            throw DomainCredentialEnvelopeError.scopeMismatch
        }
        guard bytes.count <= Self.maximumPayloadBytes else {
            throw DomainCredentialEnvelopeError.payloadTooLarge
        }
        pruneExpiredRecords()
        guard activeEnvelopeCount < Self.maximumOutstandingEnvelopeCount else {
            throw DomainCredentialEnvelopeError.tooManyOutstandingEnvelopes
        }
        let descriptor = DomainCredentialEnvelopeDescriptor(
            envelopeID: UUID(),
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            scope: scope,
            expiresAt: clock.now.advanced(by: lifetime)
        )
        records[descriptor.envelopeID] = Record(
            descriptor: descriptor,
            storage: DomainSecureCredentialBuffer(bytes: bytes),
            state: .active
        )
        activeEnvelopeCount += 1
        scheduleExpiry(for: descriptor)
        return descriptor
    }

    package func redeem(
        _ descriptor: DomainCredentialEnvelopeDescriptor,
        scope: DomainCredentialScope
    ) throws -> DomainCredentialPayload {
        guard let record = records[descriptor.envelopeID] else {
            throw DomainCredentialEnvelopeError.unavailable
        }
        guard descriptor.runtimeID == record.descriptor.runtimeID,
              descriptor.runtimeGeneration == record.descriptor.runtimeGeneration
        else {
            throw DomainCredentialEnvelopeError.runtimeMismatch
        }
        guard descriptor.scope == record.descriptor.scope,
              scope == record.descriptor.scope
        else {
            throw DomainCredentialEnvelopeError.scopeMismatch
        }
        guard descriptor.expiresAt == record.descriptor.expiresAt else {
            throw DomainCredentialEnvelopeError.unavailable
        }
        guard descriptor.runtimeID == identity.runtimeID,
              descriptor.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw DomainCredentialEnvelopeError.runtimeMismatch
        }
        switch record.state {
        case .consumed:
            throw DomainCredentialEnvelopeError.alreadyConsumed
        case .expired:
            throw DomainCredentialEnvelopeError.expired
        case .revoked:
            throw DomainCredentialEnvelopeError.revoked
        case .active:
            break
        }
        guard clock.now < record.descriptor.expiresAt else {
            expire(envelopeID: descriptor.envelopeID)
            throw DomainCredentialEnvelopeError.expired
        }
        guard let sourceStorage = record.storage else {
            throw DomainCredentialEnvelopeError.alreadyConsumed
        }
        let payloadStorage: DomainSecureCredentialBuffer
        do {
            payloadStorage = try sourceStorage.clone()
        } catch {
            throw DomainCredentialEnvelopeError.alreadyConsumed
        }
        transitionToTerminal(envelopeID: descriptor.envelopeID, state: .consumed)
        return DomainCredentialPayload(
            storage: payloadStorage,
            expiresAt: record.descriptor.expiresAt
        )
    }

    private func scheduleExpiry(for descriptor: DomainCredentialEnvelopeDescriptor) {
        let envelopeID = descriptor.envelopeID
        expiryTasks[envelopeID] = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: descriptor.expiresAt)
            } catch {
                return
            }
            await self?.expire(envelopeID: envelopeID)
        }
    }

    private func pruneExpiredRecords() {
        let now = clock.now
        let expiredIDs = records.compactMap { id, record -> UUID? in
            guard record.state == .active, now >= record.descriptor.expiresAt else { return nil }
            return id
        }
        for id in expiredIDs {
            expire(envelopeID: id)
        }
    }

    private func expire(envelopeID: UUID) {
        guard let record = records[envelopeID], record.state == .active else { return }
        guard clock.now >= record.descriptor.expiresAt else {
            scheduleExpiry(for: record.descriptor)
            return
        }
        expiryTasks.removeValue(forKey: envelopeID)?.cancel()
        transitionToTerminal(envelopeID: envelopeID, state: .expired)
    }

    private func transitionToTerminal(envelopeID: UUID, state: State) {
        guard var record = records[envelopeID], record.state == .active else { return }
        expiryTasks.removeValue(forKey: envelopeID)?.cancel()
        record.storage?.zeroInPlace()
        record.storage = nil
        record.state = state
        records[envelopeID] = record
        activeEnvelopeCount = max(0, activeEnvelopeCount - 1)
        terminalOrder.append(envelopeID)
        trimTombstones()
    }

    private func trimTombstones() {
        while terminalOrder.count > Self.maximumTombstoneCount {
            let oldest = terminalOrder.removeFirst()
            records.removeValue(forKey: oldest)
        }
    }

    package func revoke(_ envelopeID: UUID) {
        guard records[envelopeID]?.state == .active else { return }
        expiryTasks.removeValue(forKey: envelopeID)?.cancel()
        transitionToTerminal(envelopeID: envelopeID, state: .revoked)
    }

    package func shutdown() {
        isShuttingDown = true
        for task in expiryTasks.values {
            task.cancel()
        }
        expiryTasks.removeAll()
        let activeIDs = records.compactMap { id, record in
            record.state == .active ? id : nil
        }
        for id in activeIDs {
            transitionToTerminal(envelopeID: id, state: .revoked)
        }
    }

    #if DEBUG
        package func test_ownedStorageBytes(envelopeID: UUID) -> [UInt8]? {
            records[envelopeID]?.storage?.testSnapshot()
        }

        package func test_isOwnedStorageZeroed(envelopeID: UUID) -> Bool? {
            guard let record = records[envelopeID] else { return nil }
            return record.storage?.testIsZeroed() ?? (record.state != .active)
        }

        package func test_recordCount() -> Int {
            records.count
        }

        package func test_activeEnvelopeCount() -> Int {
            activeEnvelopeCount
        }

        package func test_tombstoneCount() -> Int {
            terminalOrder.count
        }

        package func test_terminalStorageCount() -> Int {
            records.values.reduce(into: 0) { count, record in
                if record.state != .active, record.storage != nil {
                    count += 1
                }
            }
        }

        package func test_expiryTaskCount() -> Int {
            expiryTasks.count
        }
    #endif
}

package struct DomainChildLaunchLanePlan: Hashable, Sendable {
    package let launchID: UUID
    package let providerIdentifier: String
    package let oracleLaneID: OracleLaneID?

    package init(
        launchID: UUID = UUID(),
        providerIdentifier: String,
        oracleLaneID: OracleLaneID? = nil
    ) {
        self.launchID = launchID
        self.providerIdentifier = providerIdentifier
        self.oracleLaneID = oracleLaneID
    }
}

package enum DomainChildLaunchPlanError: Error, Equatable, Sendable {
    case invalidLaneCount
    case invalidLanePrefix
    case duplicateLaunchID
    case carrierMismatch
}

package struct DomainChildLaunchPlan: Sendable {
    package let runID: UUID
    package let oracleGroupID: OracleGroupID?
    package let oracleGroupClaimID: UUID?
    package let lanes: [DomainChildLaunchLanePlan]
    package let approvalMetadata: [String: String]

    package init(
        runID: UUID,
        oracleGroupID: OracleGroupID? = nil,
        oracleGroupClaimID: UUID? = nil,
        lanes: [DomainChildLaunchLanePlan],
        approvalMetadata: [String: String] = [:]
    ) throws {
        guard (1 ... OracleRosterContract.maximumCount).contains(lanes.count) else {
            throw DomainChildLaunchPlanError.invalidLaneCount
        }
        guard Set(lanes.map(\.launchID)).count == lanes.count else {
            throw DomainChildLaunchPlanError.duplicateLaunchID
        }
        let oracleLanes = lanes.compactMap(\.oracleLaneID)
        if oracleGroupID != nil || oracleGroupClaimID != nil || !oracleLanes.isEmpty {
            guard oracleGroupID != nil,
                  oracleGroupClaimID != nil,
                  oracleLanes.count == lanes.count,
                  oracleLanes.map(\.index) == Array(lanes.indices)
            else {
                throw DomainChildLaunchPlanError.invalidLanePrefix
            }
        }
        self.runID = runID
        self.oracleGroupID = oracleGroupID
        self.oracleGroupClaimID = oracleGroupClaimID
        self.lanes = lanes
        var metadata = approvalMetadata
        metadata["lane_count"] = "\(lanes.count)"
        metadata["providers"] = lanes.map(\.providerIdentifier).joined(separator: ",")
        if let oracleGroupID { metadata["oracle_group_id"] = oracleGroupID.rawValue.uuidString }
        self.approvalMetadata = metadata
    }
}

package struct DomainChildLaunchCarrierBundle: Sendable {
    package let plan: DomainChildLaunchPlan
    package let carriers: [DomainChildLaunchCarrier]

    package init(plan: DomainChildLaunchPlan, carriers: [DomainChildLaunchCarrier]) throws {
        guard carriers.count == plan.lanes.count,
              carriers.map(\.runID).allSatisfy({ $0 == plan.runID }),
              carriers.map(\.launchID) == plan.lanes.map(\.launchID),
              carriers.map(\.providerIdentifier) == plan.lanes.map { Optional($0.providerIdentifier) },
              carriers.map(\.oracleLaneID) == plan.lanes.map(\.oracleLaneID),
              carriers.allSatisfy({
                  $0.oracleGroupID == plan.oracleGroupID
                      && $0.oracleGroupClaimID == plan.oracleGroupClaimID
              })
        else {
            throw DomainChildLaunchPlanError.carrierMismatch
        }
        self.plan = plan
        self.carriers = carriers
    }

    package var singleCarrier: DomainChildLaunchCarrier? {
        carriers.count == 1 ? carriers[0] : nil
    }

    package func carrier(for laneID: OracleLaneID) -> DomainChildLaunchCarrier? {
        carriers.first { $0.oracleLaneID == laneID }
    }
}

package struct DomainChildLaunchCarrier: Sendable {
    package static let endpointEnvironmentKey = "REPOPROMPT_MCP_PRIVATE_ENDPOINT"
    package static let launchTokenEnvironmentKey = "REPOPROMPT_MCP_LAUNCH_TOKEN"
    package static let credentialEnvelopeEnvironmentKey = "REPOPROMPT_MCP_CREDENTIAL_ENVELOPE"
    package static let clientPrincipalEnvironmentKey = "REPOPROMPT_MCP_CLIENT_PRINCIPAL"
    package static let providerIdentifierEnvironmentKey = "REPOPROMPT_MCP_PROVIDER_IDENTIFIER"
    package static let runIDEnvironmentKey = "REPOPROMPT_MCP_RUN_ID"
    package static let launchIDEnvironmentKey = "REPOPROMPT_MCP_LAUNCH_ID"
    package static let oracleGroupIDEnvironmentKey = "REPOPROMPT_MCP_ORACLE_GROUP_ID"
    package static let oracleLaneIDEnvironmentKey = "REPOPROMPT_MCP_ORACLE_LANE_ID"
    package static let oracleGroupClaimIDEnvironmentKey = "REPOPROMPT_MCP_ORACLE_GROUP_CLAIM_ID"

    package let runID: UUID
    package let launchID: UUID
    package let providerIdentifier: String?
    package let oracleGroupID: OracleGroupID?
    package let oracleLaneID: OracleLaneID?
    package let oracleGroupClaimID: UUID?
    package let launchTokenID: UUID
    package let credentialEnvelope: DomainCredentialEnvelopeDescriptor?
    package let environment: [String: String]

    package init(
        runID: UUID,
        launchID: UUID = UUID(),
        providerIdentifier: String? = nil,
        oracleGroupID: OracleGroupID? = nil,
        oracleLaneID: OracleLaneID? = nil,
        oracleGroupClaimID: UUID? = nil,
        launchTokenID: UUID,
        credentialEnvelope: DomainCredentialEnvelopeDescriptor?,
        environment: [String: String]
    ) {
        self.runID = runID
        self.launchID = launchID
        self.providerIdentifier = providerIdentifier
        self.oracleGroupID = oracleGroupID
        self.oracleLaneID = oracleLaneID
        self.oracleGroupClaimID = oracleGroupClaimID
        self.launchTokenID = launchTokenID
        self.credentialEnvelope = credentialEnvelope
        self.environment = environment
    }
}

package struct DomainPrivateChildLaunchHarness: Sendable {
    package typealias IssueLaunchToken = @Sendable (
        _ request: DomainRunLaunchReservationRequest
    ) async throws -> DomainRunLaunchToken
    package typealias RevokeLaunchToken = @Sendable (_ tokenID: UUID) async -> Void

    private let endpointDescriptor: String
    private let issueLaunchToken: IssueLaunchToken
    private let revokeLaunchToken: RevokeLaunchToken
    private let credentialStore: DomainCredentialEnvelopeStore

    package init(
        endpointDescriptor: String,
        credentialStore: DomainCredentialEnvelopeStore,
        issueLaunchToken: @escaping IssueLaunchToken,
        revokeLaunchToken: @escaping RevokeLaunchToken = { _ in }
    ) {
        self.endpointDescriptor = endpointDescriptor
        self.credentialStore = credentialStore
        self.issueLaunchToken = issueLaunchToken
        self.revokeLaunchToken = revokeLaunchToken
    }

    package func prepare(
        request: DomainRunLaunchReservationRequest,
        credential: (bytes: [UInt8], scope: DomainCredentialScope)? = nil
    ) async throws -> DomainChildLaunchCarrier {
        let oracleIdentityCount = [
            request.oracleGroupID != nil,
            request.oracleLaneID != nil,
            request.oracleGroupClaimID != nil,
        ].count(where: { $0 })
        guard oracleIdentityCount == 0 || oracleIdentityCount == 3 else {
            throw DomainRunLaunchTokenError.incompleteOracleIdentity
        }
        if let credential {
            let scope = credential.scope
            let isGrouped = request.oracleGroupID != nil
                || request.oracleLaneID != nil
                || request.oracleGroupClaimID != nil
            let identityMatches = if isGrouped {
                scope.launchID == request.launchID
                    && scope.oracleGroupID == request.oracleGroupID
                    && scope.oracleLaneID == request.oracleLaneID
                    && scope.oracleGroupClaimID == request.oracleGroupClaimID
            } else {
                (scope.launchID == nil || scope.launchID == request.launchID)
                    && (scope.oracleGroupID == nil || scope.oracleGroupID == request.oracleGroupID)
                    && (scope.oracleLaneID == nil || scope.oracleLaneID == request.oracleLaneID)
                    && (scope.oracleGroupClaimID == nil
                        || scope.oracleGroupClaimID == request.oracleGroupClaimID)
            }
            guard scope.providerIdentifier == request.providerIdentifier,
                  scope.runID == request.runID,
                  identityMatches
            else {
                throw DomainCredentialEnvelopeError.scopeMismatch
            }
        }
        let token = try await issueLaunchToken(request)
        let descriptor: DomainCredentialEnvelopeDescriptor?
        do {
            if let credential {
                descriptor = try await credentialStore.issue(bytes: credential.bytes, scope: credential.scope)
            } else {
                descriptor = nil
            }
        } catch {
            await revokeLaunchToken(token.tokenID)
            throw error
        }
        var environment = [
            DomainChildLaunchCarrier.endpointEnvironmentKey: endpointDescriptor,
            DomainChildLaunchCarrier.launchTokenEnvironmentKey: token.material,
            DomainChildLaunchCarrier.clientPrincipalEnvironmentKey: request.clientPrincipal,
            DomainChildLaunchCarrier.providerIdentifierEnvironmentKey: request.providerIdentifier,
            DomainChildLaunchCarrier.runIDEnvironmentKey: request.runID.uuidString,
            DomainChildLaunchCarrier.launchIDEnvironmentKey: request.launchID.uuidString
        ]
        if let groupID = request.oracleGroupID {
            environment[DomainChildLaunchCarrier.oracleGroupIDEnvironmentKey] = groupID.rawValue.uuidString
        }
        if let laneID = request.oracleLaneID {
            environment[DomainChildLaunchCarrier.oracleLaneIDEnvironmentKey] = "\(laneID.index)"
        }
        if let claimID = request.oracleGroupClaimID {
            environment[DomainChildLaunchCarrier.oracleGroupClaimIDEnvironmentKey] = claimID.uuidString
        }
        if let descriptor {
            environment[DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey] =
                descriptor.envelopeID.uuidString
        }
        return DomainChildLaunchCarrier(
            runID: request.runID,
            launchID: request.launchID,
            providerIdentifier: request.providerIdentifier,
            oracleGroupID: request.oracleGroupID,
            oracleLaneID: request.oracleLaneID,
            oracleGroupClaimID: request.oracleGroupClaimID,
            launchTokenID: token.tokenID,
            credentialEnvelope: descriptor,
            environment: environment
        )
    }
}
