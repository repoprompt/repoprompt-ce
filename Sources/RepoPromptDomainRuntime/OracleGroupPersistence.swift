import Foundation

package enum OraclePersistenceError: Error, LocalizedError, Equatable, Sendable {
    case alreadyExists
    case notFound
    case revisionConflict(expected: UInt64, actual: UInt64)
    case invalidDocument(String)
    case ownerMismatch
    case ambiguousMemberAlias
    case artifactMissing(String)
    case artifactDigestMismatch(String)
    case futureSchema(Int)
    case invalidRetentionCount

    package var errorDescription: String? {
        switch self {
        case .alreadyExists:
            "Oracle persistence record already exists."
        case .notFound:
            "Oracle persistence record was not found."
        case let .revisionConflict(expected, actual):
            "Oracle persistence revision changed (expected \(expected), actual \(actual))."
        case let .invalidDocument(reason):
            "Oracle persistence document is invalid: \(reason)."
        case .ownerMismatch:
            "Oracle conversation route owner does not match the persisted group."
        case .ambiguousMemberAlias:
            "Oracle member alias is ambiguous inside its route."
        case let .artifactMissing(id):
            "Oracle context artifact \(id) is missing."
        case let .artifactDigestMismatch(id):
            "Oracle context artifact \(id) failed digest verification."
        case let .futureSchema(version):
            "Oracle persistence schema \(version) is newer than this runtime supports."
        case .invalidRetentionCount:
            "Oracle retention count must be non-negative."
        }
    }
}

package enum OraclePersistenceMutationPhase: Sendable {
    case journalPersisted(UUID)
    case writeApplied(UUID, Int)
}

package enum OracleStoredConversation: Sendable {
    case single(OracleSingleConversationDocument)
    case group(OracleGroupDocument)
}

package actor DomainOracleConversationStore: OracleGroupStore, OracleSingleConversationStore, OracleArtifactStore {
    package typealias MutationObserver = @Sendable (OraclePersistenceMutationPhase) throws -> Void

    private let root: URL
    private let mutationObserver: MutationObserver

    package init(
        persistence: DomainPersistenceCoordinator,
        mutationObserver: @escaping MutationObserver = { _ in }
    ) {
        root = persistence.oracleStorageRoot
        self.mutationObserver = mutationObserver
    }

    package func create(_ group: OracleGroupDocument) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                try files.validatePreparedCreate(group)
                let groupURL = files.groupURL(group.group.id)
                guard !files.exists(groupURL) else { throw OraclePersistenceError.alreadyExists }
                var index = try files.loadIndex()
                let newEntries = group.members.map {
                    OracleMemberIndexEntry(
                        owner: group.owner,
                        publicChatID: $0.publicChatID,
                        groupID: group.group.id,
                        laneIndex: $0.laneID.index
                    )
                }
                for entry in newEntries {
                    guard !index.entries.contains(where: {
                        $0.owner == entry.owner && $0.publicChatID == entry.publicChatID
                    }) else {
                        throw OraclePersistenceError.ambiguousMemberAlias
                    }
                }
                index = index.replacing(entries: index.entries + newEntries)
                try files.commit([
                    .write(relativePath: files.relative(groupURL), data: try files.encode(group)),
                    .write(relativePath: files.relative(files.indexURL), data: try files.encode(index))
                ])
            }
        }
    }

    package func load(
        member: OracleMemberLookup,
        owner: OracleConversationOwner
    ) async throws -> OracleGroupDocument? {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let matches = try files.loadIndex().entries.filter {
                    $0.owner == owner && $0.publicChatID == member.publicChatID
                }
                guard matches.count <= 1 else { throw OraclePersistenceError.ambiguousMemberAlias }
                guard let match = matches.first else { return nil }
                guard let group = try files.loadGroup(match.groupID) else {
                    throw OraclePersistenceError.invalidDocument("member_index_missing_group")
                }
                guard group.owner == owner else { throw OraclePersistenceError.ownerMismatch }
                try files.validate(group)
                guard group.members.contains(where: {
                    $0.laneID.index == match.laneIndex && $0.publicChatID == member.publicChatID
                }) else {
                    throw OraclePersistenceError.invalidDocument("member_index_mismatch")
                }
                return group
            }
        }
    }

    package func load(
        groupID: OracleGroupID,
        owner: OracleConversationOwner
    ) async throws -> OracleGroupDocument? {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                guard let group = try files.loadGroup(groupID) else { return nil }
                guard group.owner == owner else { throw OraclePersistenceError.ownerMismatch }
                try files.validate(group)
                try files.validateIndex(for: group)
                return group
            }
        }
    }

    package func save(_ group: OracleGroupDocument, expectedRevision: UInt64) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                guard let current = try files.loadGroup(group.group.id) else {
                    throw OraclePersistenceError.notFound
                }
                guard current.owner == group.owner else { throw OraclePersistenceError.ownerMismatch }
                guard current.revision == expectedRevision else {
                    throw OraclePersistenceError.revisionConflict(
                        expected: expectedRevision,
                        actual: current.revision
                    )
                }
                try files.validateSave(current: current, next: group)
                try files.commit([
                    .write(
                        relativePath: files.relative(files.groupURL(group.group.id)),
                        data: try files.encode(group)
                    )
                ])
            }
        }
    }

    package func rename(
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        name: String,
        expectedRevision: UInt64
    ) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw OraclePersistenceError.invalidDocument("empty_name") }
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                guard let current = try files.loadGroup(groupID) else { throw OraclePersistenceError.notFound }
                guard current.owner == owner else { throw OraclePersistenceError.ownerMismatch }
                guard current.revision == expectedRevision else {
                    throw OraclePersistenceError.revisionConflict(
                        expected: expectedRevision,
                        actual: current.revision
                    )
                }
                try files.validate(current)
                guard current.turns.last?.state == .terminal else {
                    throw OraclePersistenceError.invalidDocument("cannot_rename_prepared_group")
                }
                let renamed = try OracleGroupDocument(
                    schemaVersion: current.schemaVersion,
                    group: current.group,
                    owner: current.owner,
                    name: name,
                    revision: current.revision &+ 1,
                    createdAt: current.createdAt,
                    updatedAt: Date(),
                    roster: current.roster,
                    members: current.members,
                    turns: current.turns
                )
                try files.commit([
                    .write(
                        relativePath: files.relative(files.groupURL(groupID)),
                        data: try files.encode(renamed)
                    )
                ])
            }
        }
    }

    package func delete(
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        expectedRevision: UInt64
    ) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let allGroups = try files.loadAndValidateAllGroups()
                guard let current = allGroups.first(where: { $0.group.id == groupID }) else {
                    throw OraclePersistenceError.notFound
                }
                guard current.owner == owner else { throw OraclePersistenceError.ownerMismatch }
                guard current.revision == expectedRevision else {
                    throw OraclePersistenceError.revisionConflict(
                        expected: expectedRevision,
                        actual: current.revision
                    )
                }
                try files.deleteGroups([current], from: allGroups)
            }
        }
    }

    package func retainMostRecentGroups(
        _ maximumCount: Int,
        owner: OracleConversationOwner
    ) async throws -> [OracleGroupID] {
        guard maximumCount >= 0 else { throw OraclePersistenceError.invalidRetentionCount }
        return try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let allGroups = try files.loadAndValidateAllGroups()
                let owned = allGroups.filter { $0.owner == owner }.sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.group.id.rawValue.uuidString < $1.group.id.rawValue.uuidString
                }
                let removed = Array(owned.dropFirst(maximumCount))
                guard !removed.isEmpty else { return [] }
                try files.deleteGroups(removed, from: allGroups)
                return removed.map(\.group.id)
            }
        }
    }

    package func deleteAllGroups(owner: OracleConversationOwner) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let allGroups = try files.loadAndValidateAllGroups()
                let owned = allGroups.filter { $0.owner == owner }
                guard !owned.isEmpty else { return }
                try files.deleteGroups(owned, from: allGroups)
            }
        }
    }

    package func deleteAllGroups(
        ownerKind: String,
        identifierPrefix: String
    ) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let allGroups = try files.loadAndValidateAllGroups()
                let owned = allGroups.filter {
                    $0.owner.kind == ownerKind && $0.owner.identifier.hasPrefix(identifierPrefix)
                }
                guard !owned.isEmpty else { return }
                try files.deleteGroups(owned, from: allGroups)
            }
        }
    }

    package func recoverPreparedGroups(
        owner: OracleConversationOwner
    ) async throws -> [OracleGroupDocument] {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                return try files.loadAndValidateAllGroups()
                    .filter { $0.owner == owner && $0.turns.last?.state == .prepared }
                    .sorted { $0.updatedAt < $1.updatedAt }
            }
        }
    }

    package func create(_ conversation: OracleSingleConversationDocument) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                try files.validate(conversation)
                guard conversation.turns.last?.state == .prepared else {
                    throw OraclePersistenceError.invalidDocument("single_must_start_prepared")
                }
                let url = files.singleURL(owner: conversation.owner, publicChatID: conversation.publicChatID)
                guard !files.exists(url) else { throw OraclePersistenceError.alreadyExists }
                try files.commit([.write(relativePath: files.relative(url), data: try files.encode(conversation))])
            }
        }
    }

    package func load(
        publicChatID: String,
        owner: OracleConversationOwner
    ) async throws -> OracleSingleConversationDocument? {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let url = files.singleURL(owner: owner, publicChatID: publicChatID)
                guard files.exists(url) else { return nil }
                let conversation = try files.decode(
                    OracleSingleConversationDocument.self,
                    from: try Data(contentsOf: url)
                )
                try files.validate(conversation)
                guard conversation.owner == owner else { throw OraclePersistenceError.ownerMismatch }
                return conversation
            }
        }
    }

    package func save(
        _ conversation: OracleSingleConversationDocument,
        expectedRevision: UInt64
    ) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let url = files.singleURL(
                    owner: conversation.owner,
                    publicChatID: conversation.publicChatID
                )
                guard files.exists(url) else { throw OraclePersistenceError.notFound }
                let current = try files.decode(
                    OracleSingleConversationDocument.self,
                    from: try Data(contentsOf: url)
                )
                guard current.revision == expectedRevision else {
                    throw OraclePersistenceError.revisionConflict(
                        expected: expectedRevision,
                        actual: current.revision
                    )
                }
                guard conversation.revision == expectedRevision &+ 1,
                      conversation.owner == current.owner,
                      conversation.publicChatID == current.publicChatID,
                      conversation.model == current.model,
                      conversation.createdAt == current.createdAt,
                      conversation.updatedAt >= current.updatedAt
                else {
                    throw OraclePersistenceError.invalidDocument("invalid_single_transition")
                }
                try files.validate(conversation)
                if current.turns.last?.state == .prepared {
                    guard conversation.turns.count == current.turns.count,
                          Array(conversation.turns.dropLast()) == Array(current.turns.dropLast()),
                          conversation.turns.last?.id == current.turns.last?.id,
                          conversation.turns.last?.input == current.turns.last?.input,
                          conversation.turns.last?.startedAt == current.turns.last?.startedAt,
                          conversation.turns.last?.state == .terminal
                    else {
                        throw OraclePersistenceError.invalidDocument("invalid_single_terminal_transition")
                    }
                } else {
                    guard conversation.turns.count == current.turns.count + 1,
                          Array(conversation.turns.dropLast()) == current.turns,
                          conversation.turns.last?.state == .prepared
                    else {
                        throw OraclePersistenceError.invalidDocument("invalid_single_prepare_transition")
                    }
                }
                try files.commit([.write(relativePath: files.relative(url), data: try files.encode(conversation))])
            }
        }
    }

    package func delete(
        publicChatID: String,
        owner: OracleConversationOwner,
        expectedRevision: UInt64
    ) async throws {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let url = files.singleURL(owner: owner, publicChatID: publicChatID)
                guard files.exists(url) else { throw OraclePersistenceError.notFound }
                let current = try files.decode(
                    OracleSingleConversationDocument.self,
                    from: try Data(contentsOf: url)
                )
                guard current.owner == owner else { throw OraclePersistenceError.ownerMismatch }
                guard current.revision == expectedRevision else {
                    throw OraclePersistenceError.revisionConflict(
                        expected: expectedRevision,
                        actual: current.revision
                    )
                }
                try files.validate(current)
                let groups = try files.loadAndValidateAllGroups()
                let singles = try files.loadAndValidateAllSingles()
                let retainedSingles = singles.filter {
                    $0.owner != owner || $0.publicChatID != publicChatID
                }
                let retainedArtifacts = Set(
                    groups.flatMap(files.referencedArtifactIDs)
                        + retainedSingles.flatMap(files.referencedArtifactIDs)
                )
                let removedArtifacts = Set(files.referencedArtifactIDs(current))
                    .subtracting(retainedArtifacts)
                var writes: [OracleTransactionWrite] = [
                    .remove(relativePath: files.relative(url))
                ]
                writes.append(contentsOf: removedArtifacts.map {
                    .remove(relativePath: files.relative(files.artifactURL($0)))
                })
                try files.commit(writes)
            }
        }
    }

    package func storeArtifact(_ data: Data) async throws -> String {
        let digest = DomainContentDigest.sha256(data)
        return try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let url = files.artifactURL(digest)
                if files.exists(url) {
                    guard DomainContentDigest.sha256(try Data(contentsOf: url)) == digest else {
                        throw OraclePersistenceError.artifactDigestMismatch(digest)
                    }
                } else {
                    try DomainPersistenceLock.atomicWrite(data, to: url)
                }
                return digest
            }
        }
    }

    package func loadArtifact(id: String) async throws -> Data {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                return try files.loadArtifact(id)
            }
        }
    }

    package func loadMostRecentConversation(
        owner: OracleConversationOwner
    ) async throws -> OracleStoredConversation? {
        try await perform { files in
            try files.withMutationLock {
                try files.recoverTransactions()
                let groups = try files.loadAndValidateAllGroups()
                    .filter { $0.owner == owner }
                    .map { ($0.updatedAt, OracleStoredConversation.group($0)) }
                let singles = try files.loadAndValidateAllSingles()
                    .filter { $0.owner == owner }
                    .map { ($0.updatedAt, OracleStoredConversation.single($0)) }
                return (groups + singles).max { lhs, rhs in lhs.0 < rhs.0 }?.1
            }
        }
    }

    package func recoverInterruptedTransactions() async throws {
        try await perform { files in
            try files.withMutationLock { try files.recoverTransactions() }
        }
    }

    private func perform<T: Sendable>(
        _ body: @escaping @Sendable (OracleStorageFiles) throws -> T
    ) async throws -> T {
        let root = root
        let observer = mutationObserver
        return try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            return try body(OracleStorageFiles(
                root: root,
                cancellation: cancellation,
                mutationObserver: observer
            ))
        }
    }
}

private struct OracleMemberIndexEntry: Codable, Equatable, Sendable {
    let owner: OracleConversationOwner
    let publicChatID: String
    let groupID: OracleGroupID
    let laneIndex: Int
}

private struct OracleMemberIndexDocument: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let revision: UInt64
    let entries: [OracleMemberIndexEntry]

    init(version: Int = currentVersion, revision: UInt64 = 0, entries: [OracleMemberIndexEntry] = []) {
        self.version = version
        self.revision = revision
        self.entries = entries
    }

    func replacing(entries: [OracleMemberIndexEntry]) -> Self {
        Self(
            revision: revision &+ 1,
            entries: entries.sorted {
                let lhs = "\($0.owner.kind)|\($0.owner.identifier)|\($0.publicChatID)|\($0.laneIndex)"
                let rhs = "\($1.owner.kind)|\($1.owner.identifier)|\($1.publicChatID)|\($1.laneIndex)"
                return lhs < rhs
            }
        )
    }
}

private struct OracleTransactionWrite: Codable, Sendable {
    let relativePath: String
    let data: Data?

    static func write(relativePath: String, data: Data) -> Self {
        Self(relativePath: relativePath, data: data)
    }

    static func remove(relativePath: String) -> Self {
        Self(relativePath: relativePath, data: nil)
    }
}

private struct OracleTransactionJournal: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let operationID: UUID
    let writes: [OracleTransactionWrite]

    init(operationID: UUID, writes: [OracleTransactionWrite]) {
        version = Self.currentVersion
        self.operationID = operationID
        self.writes = writes
    }
}

private struct OracleStorageFiles: @unchecked Sendable {
    let root: URL
    let cancellation: DomainBlockingCancellation
    let mutationObserver: DomainOracleConversationStore.MutationObserver

    var indexURL: URL { root.appendingPathComponent("index.json") }
    private var groupsDirectory: URL { root.appendingPathComponent("groups", isDirectory: true) }
    private var singlesDirectory: URL { root.appendingPathComponent("singles", isDirectory: true) }
    private var artifactsDirectory: URL { root.appendingPathComponent("artifacts", isDirectory: true) }
    private var transactionsDirectory: URL { root.appendingPathComponent("transactions", isDirectory: true) }
    private var mutationLockURL: URL {
        root.appendingPathComponent("locks", isDirectory: true).appendingPathComponent("mutation.lock")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        JSONDecoder()
    }

    func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func groupURL(_ id: OracleGroupID) -> URL {
        groupsDirectory.appendingPathComponent("\(id.rawValue.uuidString).json")
    }

    func artifactURL(_ id: String) -> URL { artifactsDirectory.appendingPathComponent("\(id).blob") }

    func singleURL(owner: OracleConversationOwner, publicChatID: String) -> URL {
        let key = "\(owner.kind)\u{0}\(owner.identifier)\u{0}\(publicChatID)"
        return singlesDirectory.appendingPathComponent("\(DomainContentDigest.sha256(Data(key.utf8))).json")
    }

    func relative(_ url: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        try DomainPersistenceLock.withLock(at: mutationLockURL, cancellation: cancellation, body)
    }

    func commit(_ writes: [OracleTransactionWrite]) throws {
        let operationID = UUID()
        let journal = OracleTransactionJournal(operationID: operationID, writes: writes)
        let journalURL = transactionsDirectory.appendingPathComponent("\(operationID.uuidString).json")
        try DomainPersistenceLock.atomicWrite(try encode(journal), to: journalURL)
        try mutationObserver(.journalPersisted(operationID))
        try apply(journal)
        try FileManager.default.removeItem(at: journalURL)
    }

    func recoverTransactions() throws {
        guard exists(transactionsDirectory) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: transactionsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            try cancellation.check()
            let journal = try decode(OracleTransactionJournal.self, from: Data(contentsOf: url))
            guard journal.version == OracleTransactionJournal.currentVersion else {
                throw OraclePersistenceError.futureSchema(journal.version)
            }
            try apply(journal, notify: false)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func apply(_ journal: OracleTransactionJournal, notify: Bool = true) throws {
        for (index, write) in journal.writes.enumerated() {
            try cancellation.check()
            let destination = try validatedURL(for: write.relativePath)
            if let data = write.data {
                try DomainPersistenceLock.atomicWrite(data, to: destination)
            } else if exists(destination) {
                try FileManager.default.removeItem(at: destination)
            }
            if notify { try mutationObserver(.writeApplied(journal.operationID, index)) }
        }
    }

    private func validatedURL(for relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw OraclePersistenceError.invalidDocument("invalid_transaction_path")
        }
        let allowed = ["groups/", "singles/", "artifacts/", "index.json"]
        guard allowed.contains(where: { relativePath == $0 || relativePath.hasPrefix($0) }) else {
            throw OraclePersistenceError.invalidDocument("invalid_transaction_path")
        }
        return root.appendingPathComponent(relativePath)
    }

    func loadIndex() throws -> OracleMemberIndexDocument {
        guard exists(indexURL) else { return OracleMemberIndexDocument() }
        let index = try decode(OracleMemberIndexDocument.self, from: Data(contentsOf: indexURL))
        guard index.version == OracleMemberIndexDocument.currentVersion else {
            throw OraclePersistenceError.futureSchema(index.version)
        }
        return index
    }

    func loadGroup(_ id: OracleGroupID) throws -> OracleGroupDocument? {
        let url = groupURL(id)
        guard exists(url) else { return nil }
        return try decode(OracleGroupDocument.self, from: Data(contentsOf: url))
    }

    func loadAndValidateAllGroups() throws -> [OracleGroupDocument] {
        guard exists(groupsDirectory) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: groupsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let groups = try urls.map {
            try decode(OracleGroupDocument.self, from: Data(contentsOf: $0))
        }
        for group in groups {
            try validate(group)
            try validateIndex(for: group)
        }
        return groups
    }

    func loadAndValidateAllSingles() throws -> [OracleSingleConversationDocument] {
        guard exists(singlesDirectory) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: singlesDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let singles = try urls.map {
            try decode(OracleSingleConversationDocument.self, from: Data(contentsOf: $0))
        }
        for single in singles { try validate(single) }
        return singles
    }

    func validatePreparedCreate(_ group: OracleGroupDocument) throws {
        try validate(group)
        guard group.revision > 0,
              group.turns.last?.state == .prepared
        else {
            throw OraclePersistenceError.invalidDocument("group_must_start_prepared")
        }
    }

    func validate(_ group: OracleGroupDocument) throws {
        guard group.schemaVersion == OracleGroupDocument.currentSchemaVersion else {
            throw OraclePersistenceError.futureSchema(group.schemaVersion)
        }
        guard group.group.size == group.roster.count,
              group.members.count == group.group.size,
              group.members.map(\.laneID.index) == Array(group.members.indices),
              Set(group.members.map(\.memberID)).count == group.members.count,
              Set(group.members.map(\.publicChatID)).count == group.members.count,
              group.members.map(\.model) == group.roster.orderedModels,
              group.revision > 0
        else {
            throw OraclePersistenceError.invalidDocument("invalid_group_topology")
        }
        guard Set(group.turns.map(\.id)).count == group.turns.count else {
            throw OraclePersistenceError.invalidDocument("duplicate_turn_id")
        }
        for (index, turn) in group.turns.enumerated() {
            try validateInput(turn.input)
            switch turn.state {
            case .prepared:
                guard index == group.turns.count - 1,
                      turn.finishedAt == nil,
                      turn.results.isEmpty
                else {
                    throw OraclePersistenceError.invalidDocument("invalid_prepared_turn")
                }
            case .terminal:
                guard turn.finishedAt != nil,
                      turn.results.count == group.group.size,
                      turn.results.map(\.laneIndex) == Array(turn.results.indices)
                else {
                    throw OraclePersistenceError.invalidDocument("invalid_terminal_turn")
                }
                for (laneIndex, result) in turn.results.enumerated() {
                    let member = group.members[laneIndex]
                    guard result.chatID == member.publicChatID,
                          result.modelID == member.model.modelID,
                          result.providerID == member.model.providerID
                    else {
                        throw OraclePersistenceError.invalidDocument("lane_result_identity_mismatch")
                    }
                }
            }
        }
    }

    func validateSave(current: OracleGroupDocument, next: OracleGroupDocument) throws {
        try validate(current)
        try validate(next)
        guard next.revision == current.revision &+ 1,
              next.schemaVersion == current.schemaVersion,
              next.group == current.group,
              next.owner == current.owner,
              next.name == current.name,
              next.createdAt == current.createdAt,
              next.roster == current.roster,
              next.members.map({ ($0.laneID, $0.memberID, $0.publicChatID, $0.model) })
                .elementsEqual(current.members.map({ ($0.laneID, $0.memberID, $0.publicChatID, $0.model) }), by: ==),
              next.updatedAt >= current.updatedAt
        else {
            throw OraclePersistenceError.invalidDocument("immutable_group_identity_changed")
        }
        if current.turns.last?.state == .prepared {
            guard next.turns.count == current.turns.count,
                  Array(next.turns.dropLast()) == Array(current.turns.dropLast()),
                  next.turns.last?.id == current.turns.last?.id,
                  next.turns.last?.input == current.turns.last?.input,
                  next.turns.last?.startedAt == current.turns.last?.startedAt,
                  next.turns.last?.state == .terminal
            else {
                throw OraclePersistenceError.invalidDocument("invalid_terminal_transition")
            }
        } else {
            guard next.turns.count == current.turns.count + 1,
                  Array(next.turns.dropLast()) == current.turns,
                  next.turns.last?.state == .prepared
            else {
                throw OraclePersistenceError.invalidDocument("invalid_prepare_transition")
            }
        }
    }

    func validate(_ conversation: OracleSingleConversationDocument) throws {
        guard conversation.schemaVersion == OracleSingleConversationDocument.currentSchemaVersion else {
            throw OraclePersistenceError.futureSchema(conversation.schemaVersion)
        }
        guard conversation.revision > 0,
              !conversation.publicChatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(conversation.turns.map(\.id)).count == conversation.turns.count
        else {
            throw OraclePersistenceError.invalidDocument("invalid_single")
        }
        for (index, turn) in conversation.turns.enumerated() {
            try validateInput(turn.input)
            switch turn.state {
            case .prepared:
                guard index == conversation.turns.count - 1,
                      turn.finishedAt == nil,
                      turn.results.isEmpty
                else {
                    throw OraclePersistenceError.invalidDocument("invalid_single_prepared_turn")
                }
            case .terminal:
                guard turn.finishedAt != nil,
                      turn.results.count == 1,
                      turn.results[0].laneIndex == 0,
                      turn.results[0].chatID == conversation.publicChatID,
                      turn.results[0].modelID == conversation.model.modelID,
                      turn.results[0].providerID == conversation.model.providerID
                else {
                    throw OraclePersistenceError.invalidDocument("invalid_single_terminal_turn")
                }
            }
        }
    }

    func validateIndex(for group: OracleGroupDocument) throws {
        let entries = try loadIndex().entries.filter { $0.groupID == group.group.id }
        guard entries.count == group.group.size,
              entries.map(\.laneIndex).sorted() == Array(group.members.indices)
        else {
            throw OraclePersistenceError.invalidDocument("incomplete_member_index")
        }
        for entry in entries {
            guard entry.owner == group.owner,
                  group.members[entry.laneIndex].publicChatID == entry.publicChatID
            else {
                throw OraclePersistenceError.invalidDocument("member_index_mismatch")
            }
        }
    }

    func validateInput(_ input: OracleInput) throws {
        guard let context = input.context else { return }
        let data: Data
        switch context.content {
        case let .inline(text):
            data = Data(text.utf8)
        case let .durableArtifact(id):
            guard id == context.sha256 else {
                throw OraclePersistenceError.artifactDigestMismatch(id)
            }
            data = try loadArtifact(id)
        }
        guard DomainContentDigest.sha256(data) == context.sha256 else {
            throw OraclePersistenceError.artifactDigestMismatch(context.sha256)
        }
    }

    func loadArtifact(_ id: String) throws -> Data {
        let url = artifactURL(id)
        guard exists(url) else { throw OraclePersistenceError.artifactMissing(id) }
        let data = try Data(contentsOf: url)
        guard DomainContentDigest.sha256(data) == id else {
            throw OraclePersistenceError.artifactDigestMismatch(id)
        }
        return data
    }

    func deleteGroups(_ removed: [OracleGroupDocument], from allGroups: [OracleGroupDocument]) throws {
        let removedIDs = Set(removed.map(\.group.id))
        var index = try loadIndex()
        index = index.replacing(entries: index.entries.filter { !removedIDs.contains($0.groupID) })
        let retained = allGroups.filter { !removedIDs.contains($0.group.id) }
        let retainedSingles = try loadAndValidateAllSingles()
        let retainedArtifacts = Set(
            retained.flatMap(referencedArtifactIDs)
                + retainedSingles.flatMap(referencedArtifactIDs)
        )
        let removedArtifacts = Set(removed.flatMap(referencedArtifactIDs)).subtracting(retainedArtifacts)
        var writes = removed.map { OracleTransactionWrite.remove(relativePath: relative(groupURL($0.group.id))) }
        writes.append(.write(relativePath: relative(indexURL), data: try encode(index)))
        writes.append(contentsOf: removedArtifacts.map {
            .remove(relativePath: relative(artifactURL($0)))
        })
        try commit(writes)
    }

    func referencedArtifactIDs(_ group: OracleGroupDocument) -> [String] {
        referencedArtifactIDs(group.turns)
    }

    func referencedArtifactIDs(_ conversation: OracleSingleConversationDocument) -> [String] {
        referencedArtifactIDs(conversation.turns)
    }

    private func referencedArtifactIDs(_ turns: [OracleTurnRecord]) -> [String] {
        turns.compactMap { turn in
            guard case let .durableArtifact(id)? = turn.input.context?.content else { return nil }
            return id
        }
    }
}
