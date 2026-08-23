import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

public struct LegacyImportReport: Codable, Equatable, Sendable {
    public let sourceDigest: String
    public let discoveredFiles: Int
    public let importedProjects: Int
    public let importedSessions: Int
    public let skippedRecords: Int
}

public enum LegacySessionJSONImporter {
    private struct Record {
        let sourceURL: URL
        let sourceDigest: String
        let object: [String: Any]
        let sessionID: UUID
        let projectID: UUID
        let parentSessionID: UUID?
    }

    public static func run(source: URL, store: SQLiteServiceStore, projectRoot: URL? = nil, faultAfterImportedSessions: Int? = nil) async throws -> LegacyImportReport {
        let files = try jsonFiles(at: source)
        var records: [Record] = []
        var skipped = 0
        var aggregate = Data()
        for file in files {
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard data.count <= 64 * 1_024 * 1_024 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Legacy session JSON exceeds the 64 MiB per-file limit")
            }
            aggregate.append(Data(file.path.utf8))
            aggregate.append(data)
            let objects = try sessionObjects(from: data)
            if objects.isEmpty { skipped += 1 }
            for object in objects {
                guard let sessionID = uuid(object["id"] ?? object["sessionID"]) else {
                    skipped += 1
                    continue
                }
                let projectID = uuid(object["workspaceID"] ?? object["projectID"])
                    ?? stableUUID("legacy-project:\(file.deletingLastPathComponent().path)")
                let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                records.append(Record(sourceURL: file, sourceDigest: PersistenceCryptography.bodyDigest(canonical), object: object, sessionID: sessionID, projectID: projectID, parentSessionID: uuid(object["parentSessionID"])))
            }
        }

        let importDigest = PersistenceCryptography.bodyDigest(aggregate)
        try await store.beginLegacyImport(sourceDigest: importDigest)
        let actor = ExternalActor(userID: "legacy-import", username: "legacy-import", displayName: "Legacy RepoPrompt Import")
        var sourceIsDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
        let baseRoot = (projectRoot ?? (sourceIsDirectory.boolValue ? source : source.deletingLastPathComponent())).standardizedFileURL
        var importedProjects = 0
        for projectID in Set(records.map(\.projectID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            if try await store.project(id: projectID) != nil { continue }
            let rootID = stableUUID("legacy-root:\(projectID.uuidString)")
            let cursor = try await store.nextCursor()
            let project = ProjectSnapshot(projectID: projectID, name: "Imported \(projectID.uuidString.prefix(8))", creator: actor, state: FileManager.default.fileExists(atPath: baseRoot.path) ? .active : .degraded, roots: [.init(rootID: rootID, logicalName: baseRoot.lastPathComponent.isEmpty ? "root" : baseRoot.lastPathComponent, canonicalPath: baseRoot.path, writable: false)], revision: 1, cursor: cursor)
            let digest = PersistenceCryptography.bodyDigest(Data("project:\(projectID.uuidString):\(baseRoot.path)".utf8))
            if try await store.persistImportedProject(project, sourceDigest: digest, actor: actor) { importedProjects += 1 }
        }

        let knownIDs = Set(records.map(\.sessionID))
        let roots = Dictionary(uniqueKeysWithValues: records.map { record in
            (record.sessionID, rootSessionID(for: record, records: records, knownIDs: knownIDs))
        })
        let ordered = records.sorted {
            let lhsDepth = ancestryDepth($0, records: records, knownIDs: knownIDs)
            let rhsDepth = ancestryDepth($1, records: records, knownIDs: knownIDs)
            return lhsDepth == rhsDepth ? $0.sessionID.uuidString < $1.sessionID.uuidString : lhsDepth < rhsDepth
        }
        var importedSessions = 0
        for record in ordered {
            let cursor = try await store.nextCursor()
            let transcript = legacyTranscript(record.object, sessionID: record.sessionID, actor: actor)
            let snapshot = SessionSnapshot(
                sessionID: record.sessionID,
                projectID: record.projectID,
                parentSessionID: record.parentSessionID.flatMap { knownIDs.contains($0) ? $0 : nil },
                rootSessionID: roots[record.sessionID] ?? record.sessionID,
                creator: actor,
                provider: provider(record.object["agentKind"] as? String),
                model: record.object["agentModel"] as? String,
                visibility: .privateSession,
                state: lifecycle(record.object["lastRunState"] as? String),
                runGeneration: 0,
                turnEpoch: 0,
                revision: 1,
                transcript: transcript,
                interactions: [],
                cursor: cursor
            )
            if try await store.persistImportedSession(snapshot, sourceDigest: record.sourceDigest, actor: actor) {
                importedSessions += 1
                if let faultAfterImportedSessions, importedSessions >= faultAfterImportedSessions {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Injected legacy import interruption")
                }
            }
        }
        try await store.completeLegacyImport(sourceDigest: importDigest)
        return LegacyImportReport(sourceDigest: importDigest, discoveredFiles: files.count, importedProjects: importedProjects, importedSessions: importedSessions, skippedRecords: skipped)
    }

    private static func jsonFiles(at source: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ServiceAPIError(code: .notFound, message: "Legacy JSON source does not exist")
        }
        if !isDirectory.boolValue { return [source.standardizedFileURL] }
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.path < $1.path }
    }

    private static func sessionObjects(from data: Data) throws -> [[String: Any]] {
        let value = try JSONSerialization.jsonObject(with: data)
        if let object = value as? [String: Any] { return [object] }
        return value as? [[String: Any]] ?? []
    }

    private static func legacyTranscript(_ object: [String: Any], sessionID: UUID, actor: ExternalActor) -> [TranscriptEntry] {
        var values: [[String: Any]] = object["items"] as? [[String: Any]] ?? []
        if values.isEmpty, let transcript = object["transcript"] as? [String: Any], let turns = transcript["turns"] as? [[String: Any]] {
            for turn in turns {
                if let request = turn["request"] as? [String: Any] { values.append(request.merging(["kind": "user"]) { current, _ in current }) }
                for span in turn["responseSpans"] as? [[String: Any]] ?? [] {
                    values.append(contentsOf: span["activities"] as? [[String: Any]] ?? [])
                }
            }
        }
        values.sort {
            let lhs = ($0["sequenceIndex"] as? NSNumber)?.intValue ?? 0
            let rhs = ($1["sequenceIndex"] as? NSNumber)?.intValue ?? 0
            return lhs < rhs
        }
        return values.enumerated().compactMap { offset, value in
            guard let text = value["text"] as? String, !text.isEmpty else { return nil }
            let sequence = Int64(offset + 1)
            let kind = transcriptKind(value["kind"] as? String ?? value["itemKind"] as? String ?? value["role"] as? String)
            return TranscriptEntry(entryID: uuid(value["id"]) ?? stableUUID("legacy-entry:\(sessionID.uuidString):\(sequence):\(text)"), sessionSequence: sequence, kind: kind, content: text, actor: kind == .human ? actor : nil, timestamp: date(value["timestamp"]) ?? Date(timeIntervalSince1970: 0))
        }
    }

    private static func provider(_ value: String?) -> ProviderKind {
        switch value?.lowercased() {
        case let value? where value.contains("claude"): .claudeCompatible
        case let value? where value.contains("open"): .openCodeACP
        case let value? where value.contains("cursor"): .cursorACP
        case let value? where value.contains("grok"): .grokBuildACP
        case let value? where value.contains("mcp"): .mcp
        default: .codex
        }
    }

    private static func lifecycle(_ value: String?) -> SessionLifecycleState {
        switch value?.lowercased() {
        case "running", "waitingforuser", "waitingforquestion", "waitingforapproval": .interrupted
        case "completed": .completed
        case "cancelled", "canceled": .canceled
        case "failed": .failed
        default: .idle
        }
    }

    private static func transcriptKind(_ value: String?) -> TranscriptEntry.Kind {
        switch value?.lowercased() {
        case "user", "human": .human
        case "assistant", "assistantinline": .assistant
        case "thinking", "reasoning": .reasoning
        case "toolcall", "toolresult", "tool": .tool
        case "system", "error": .system
        default: .progress
        }
    }

    private static func rootSessionID(for record: Record, records: [Record], knownIDs: Set<UUID>) -> UUID {
        var current = record
        var visited = Set([record.sessionID])
        while let parentID = current.parentSessionID, knownIDs.contains(parentID), visited.insert(parentID).inserted, let parent = records.first(where: { $0.sessionID == parentID }) { current = parent }
        return current.sessionID
    }

    private static func ancestryDepth(_ record: Record, records: [Record], knownIDs: Set<UUID>) -> Int {
        var depth = 0
        var current = record
        var visited = Set([record.sessionID])
        while let parentID = current.parentSessionID, knownIDs.contains(parentID), visited.insert(parentID).inserted, let parent = records.first(where: { $0.sessionID == parentID }) { depth += 1; current = parent }
        return depth
    }

    private static func uuid(_ value: Any?) -> UUID? {
        if let value = value as? UUID { return value }
        return (value as? String).flatMap(UUID.init(uuidString:))
    }

    private static func stableUUID(_ seed: String) -> UUID {
        let digest = PersistenceCryptography.bodyDigest(Data(seed.utf8))
        let value = "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-4\(digest.dropFirst(13).prefix(3))-a\(digest.dropFirst(17).prefix(3))-\(digest.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
