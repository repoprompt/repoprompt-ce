import CryptoKit
import Foundation

enum CodexHookGateError: LocalizedError, Equatable {
    case malformedInventory(String)
    case inventoryError(cwd: String, details: String)
    case unsupportedUntrustedSource(String)
    case reviewDeclined
    case reviewCancelled
    case inventoryDrift
    case invalidManagedConfig(String)
    case uncertainWrite(String)

    var errorDescription: String? {
        switch self {
        case let .malformedInventory(message): message
        case let .inventoryError(cwd, details): "Codex could not inventory project hooks for \(cwd): \(details)"
        case let .unsupportedUntrustedSource(source):
            "Codex reported an enabled unmanaged \(source) hook that RepoPrompt cannot safely trust. Disable or manage that hook before starting the agent."
        case .reviewDeclined: "Project hook review was declined; Codex was not started."
        case .reviewCancelled: "Project hook review was cancelled; Codex was not started."
        case .inventoryDrift: "Project hooks changed during review. Start again to review the refreshed definitions."
        case let .invalidManagedConfig(message): message
        case let .uncertainWrite(message): message
        }
    }
}

struct CodexHookInventory: Equatable {
    enum EventName: String, Codable, CaseIterable {
        case preToolUse, permissionRequest, postToolUse, preCompact, postCompact
        case sessionStart, sessionEnd, userPromptSubmit, subagentStart, subagentStop, stop
    }

    enum HandlerType: String, Codable { case command, prompt, agent }
    enum Source: String, Codable {
        case system, user, project, mdm, sessionFlags, plugin, cloudRequirements
        case cloudManagedConfig, legacyManagedConfigFile, legacyManagedConfigMdm, unknown
    }

    enum TrustStatus: String, Codable { case managed, untrusted, trusted, modified }

    struct HookError: Codable, Equatable {
        let path: String
        let message: String
    }

    struct Hook: Codable, Equatable {
        let key: String
        let eventName: EventName
        let handlerType: HandlerType
        let matcher: String?
        let command: String?
        let timeoutSec: UInt64
        let statusMessage: String?
        let additionalContextLimit: UInt64?
        let sourcePath: String
        let source: Source
        let pluginId: String?
        let displayOrder: Int64
        let enabled: Bool
        let isManaged: Bool
        let currentHash: String
        let trustStatus: TrustStatus

        var needsProjectReview: Bool {
            enabled && !isManaged && source == .project && (trustStatus == .untrusted || trustStatus == .modified)
        }

        var hasUnsupportedUntrustedSource: Bool {
            enabled && !isManaged && source != .project && (trustStatus == .untrusted || trustStatus == .modified)
        }
    }

    struct Record: Codable, Equatable {
        let cwd: String
        let hooks: [Hook]
        let warnings: [String]
        let errors: [HookError]
    }

    private struct Response: Codable { let data: [Record] }

    let records: [Record]

    var hookCount: Int {
        records.reduce(0) { $0 + $1.hooks.count }
    }

    var reviewHooks: [Hook] {
        records.flatMap(\.hooks).filter(\.needsProjectReview)
    }

    var reviewFingerprint: String {
        let material = records.flatMap { record in
            record.hooks.map { [record.cwd, $0.key, $0.currentHash, $0.trustStatus.rawValue].joined(separator: "\u{0}") }
        }.joined(separator: "\u{1}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Definition fingerprint deliberately excludes trust status so post-write verification
    /// permits only the expected trust transition while still detecting definition drift.
    var definitionFingerprint: String {
        let material = records.flatMap { record in
            record.hooks.map { hook in
                [
                    record.cwd, hook.key, hook.eventName.rawValue, hook.handlerType.rawValue,
                    hook.matcher ?? "", hook.command ?? "", String(hook.timeoutSec),
                    hook.sourcePath, hook.source.rawValue, String(hook.enabled),
                    String(hook.isManaged), hook.currentHash
                ].joined(separator: "\u{0}")
            }
        }.joined(separator: "\u{1}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ result: [String: Any], expectedCWDs: [String]) throws -> CodexHookInventory {
        guard JSONSerialization.isValidJSONObject(result) else {
            throw CodexHookGateError.malformedInventory("hooks/list returned non-JSON data.")
        }
        let response: Response
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CodexHookGateError.malformedInventory("hooks/list did not match the pinned Codex 0.147 schema.")
        }

        let expected = expectedCWDs.map { URL(fileURLWithPath: $0).standardized.path }
        guard Set(expected).count == expected.count, response.data.count == expected.count else {
            throw CodexHookGateError.malformedInventory("hooks/list returned a missing or duplicate cwd record.")
        }
        var seenCWDs = Set<String>()
        let expectedSet = Set(expected)
        var normalizedRecords: [Record] = []
        for record in response.data {
            guard record.cwd.hasPrefix("/") else {
                throw CodexHookGateError.malformedInventory("hooks/list returned a non-absolute cwd.")
            }
            let cwd = URL(fileURLWithPath: record.cwd).standardized.path
            guard record.cwd == cwd,
                  !record.cwd.utf8.contains(0),
                  expectedSet.contains(cwd),
                  seenCWDs.insert(cwd).inserted
            else {
                throw CodexHookGateError.malformedInventory("hooks/list returned an unexpected or duplicate cwd record.")
            }
            if !record.errors.isEmpty {
                let details = record.errors.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
                throw CodexHookGateError.inventoryError(cwd: cwd, details: details)
            }
            var keys = Set<String>()
            var hooks: [Hook] = []
            for hook in record.hooks {
                let key = hook.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let sourcePath = URL(fileURLWithPath: hook.sourcePath).standardized.path
                guard hook.key == key,
                      !key.isEmpty, key.count <= 4096, !key.utf8.contains(0), keys.insert(key).inserted,
                      hook.sourcePath.hasPrefix("/"), hook.sourcePath == sourcePath,
                      !hook.sourcePath.utf8.contains(0),
                      isCodexSHA256Version(hook.currentHash)
                else {
                    throw CodexHookGateError.malformedInventory("hooks/list returned an invalid or duplicate hook key, hash, or path.")
                }
                if hook.hasUnsupportedUntrustedSource {
                    throw CodexHookGateError.unsupportedUntrustedSource(hook.source.rawValue)
                }
                hooks.append(Hook(
                    key: key,
                    eventName: hook.eventName,
                    handlerType: hook.handlerType,
                    matcher: hook.matcher,
                    command: hook.command,
                    timeoutSec: hook.timeoutSec,
                    statusMessage: hook.statusMessage,
                    additionalContextLimit: hook.additionalContextLimit,
                    sourcePath: sourcePath,
                    source: hook.source,
                    pluginId: hook.pluginId,
                    displayOrder: hook.displayOrder,
                    enabled: hook.enabled,
                    isManaged: hook.isManaged,
                    currentHash: hook.currentHash.lowercased(),
                    trustStatus: hook.trustStatus
                ))
            }
            normalizedRecords.append(Record(cwd: cwd, hooks: hooks, warnings: record.warnings, errors: []))
        }
        guard seenCWDs == expectedSet else {
            throw CodexHookGateError.malformedInventory("hooks/list omitted an execution cwd record.")
        }
        normalizedRecords.sort { $0.cwd < $1.cwd }
        return CodexHookInventory(records: normalizedRecords)
    }

    private static func isCodexSHA256Version(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else { return false }
        let bytes = value.dropFirst(prefix.count).utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

struct CodexHookReview: Equatable {
    let interactionID: UUID
    let cwd: String
    let hooks: [CodexHookInventory.Hook]
    let inventoryFingerprint: String
}

enum CodexHookReviewDecision: Equatable { case trustAll, decline, cancel }

struct CodexHookGateDependencies {
    let read: @Sendable (_ method: String, _ params: [String: Any], _ timeout: TimeInterval?) async throws -> [String: Any]
    let write: @Sendable (_ method: String, _ params: [String: Any], _ timeout: TimeInterval?) async throws -> [String: Any]
    let review: @Sendable (CodexHookReview) async -> CodexHookReviewDecision
    let emitInventory: @Sendable (CodexHookInventoryDiagnostic) async -> Void
    let terminateUncertainWrite: @Sendable () async throws -> Void
    let assertAuthority: @Sendable () throws -> Void
}

enum CodexHookCompatibilityGate {
    static func run(
        cwd: String,
        managedConfigURL: URL,
        timeout: TimeInterval?,
        dependencies: CodexHookGateDependencies
    ) async throws {
        let normalizedCWD = URL(fileURLWithPath: cwd).standardized.path
        let initial = try await inventory(cwd: normalizedCWD, timeout: timeout, dependencies: dependencies)
        try dependencies.assertAuthority()
        await dependencies.emitInventory(.init(
            cwds: initial.records.map(\.cwd),
            hookCount: initial.hookCount,
            warningCount: initial.records.reduce(0) { $0 + $1.warnings.count },
            reviewRequiredCount: initial.reviewHooks.count
        ))
        try dependencies.assertAuthority()
        guard !initial.reviewHooks.isEmpty else { return }

        let review = CodexHookReview(
            interactionID: UUID(),
            cwd: normalizedCWD,
            hooks: initial.reviewHooks,
            inventoryFingerprint: initial.reviewFingerprint
        )
        let decision = await dependencies.review(review)
        try dependencies.assertAuthority()
        switch decision {
        case .decline: throw CodexHookGateError.reviewDeclined
        case .cancel: throw CodexHookGateError.reviewCancelled
        case .trustAll: break
        }

        // Snapshot the exact all-or-nothing policy before any config read or mutation.
        let approvedHashes = Dictionary(uniqueKeysWithValues: review.hooks.map { ($0.key, $0.currentHash) })
        let refreshed = try await inventory(cwd: normalizedCWD, timeout: timeout, dependencies: dependencies)
        try dependencies.assertAuthority()
        guard refreshed.reviewFingerprint == review.inventoryFingerprint else {
            throw CodexHookGateError.inventoryDrift
        }

        let configResult = try await dependencies.read(
            "config/read",
            ["includeLayers": true, "cwd": normalizedCWD],
            timeout
        )
        try dependencies.assertAuthority()
        let config = try decodeManagedConfig(result: configResult, expectedFile: managedConfigURL)

        let trustState: [String: Any] = approvedHashes.reduce(into: [:]) { result, pair in
            result[pair.key] = ["trusted_hash": pair.value]
        }
        let writeParams: [String: Any] = [
            "edits": [[
                "keyPath": "hooks.state",
                "value": trustState,
                "mergeStrategy": "upsert"
            ]],
            "filePath": config.filePath,
            "expectedVersion": config.version,
            "reloadUserConfig": true
        ]

        let writeResult: [String: Any]
        do {
            writeResult = try await dependencies.write("config/batchWrite", writeParams, timeout)
        } catch {
            try await dependencies.terminateUncertainWrite()
            throw uncertainWriteError(underlying: error)
        }
        try dependencies.assertAuthority()
        do {
            try validateWriteResponse(writeResult, expectedFile: managedConfigURL)
        } catch {
            try await dependencies.terminateUncertainWrite()
            throw uncertainWriteError(underlying: error)
        }

        let verified = try await inventory(cwd: normalizedCWD, timeout: timeout, dependencies: dependencies)
        try dependencies.assertAuthority()
        guard verified.definitionFingerprint == initial.definitionFingerprint else {
            throw CodexHookGateError.inventoryDrift
        }
        let verifiedByKey = Dictionary(uniqueKeysWithValues: verified.records.flatMap(\.hooks).map { ($0.key, $0) })
        guard approvedHashes.allSatisfy({ key, hash in
            guard let hook = verifiedByKey[key] else { return false }
            return hook.currentHash == hash && hook.trustStatus == .trusted
        }) else {
            throw CodexHookGateError.invalidManagedConfig(
                "Codex did not report the reviewed project hooks as trusted after writing managed-home config."
            )
        }
    }

    private struct ManagedConfigLayer {
        let filePath: String
        let version: String
    }

    private static func inventory(
        cwd: String,
        timeout: TimeInterval?,
        dependencies: CodexHookGateDependencies
    ) async throws -> CodexHookInventory {
        let result = try await dependencies.read("hooks/list", ["cwds": [cwd]], timeout)
        try dependencies.assertAuthority()
        return try CodexHookInventory.decode(result, expectedCWDs: [cwd])
    }

    private static func decodeManagedConfig(
        result: [String: Any],
        expectedFile: URL
    ) throws -> ManagedConfigLayer {
        guard let layers = result["layers"] as? [[String: Any]] else {
            throw CodexHookGateError.invalidManagedConfig("config/read omitted pinned user-config layers.")
        }
        let expected = expectedFile.standardized.path
        let matches = layers.compactMap { layer -> ManagedConfigLayer? in
            guard let name = layer["name"] as? [String: Any],
                  name["type"] as? String == "user",
                  name["profile"] == nil || name["profile"] is NSNull,
                  let file = name["file"] as? String,
                  file == expected,
                  let version = layer["version"] as? String,
                  !version.isEmpty
            else { return nil }
            return ManagedConfigLayer(filePath: expected, version: version)
        }
        guard matches.count == 1, let match = matches.first else {
            throw CodexHookGateError.invalidManagedConfig(
                "config/read did not return exactly one versioned RPCE-managed user config layer."
            )
        }
        return match
    }

    private static func uncertainWriteError(underlying error: Error) -> CodexHookGateError {
        .uncertainWrite(
            "Codex hook trust may have been partially written. RepoPrompt terminated the authoritative app-server transport and did not retry. Restart the agent to re-inventory current hook trust. Underlying error: \(error.localizedDescription)"
        )
    }

    private static func validateWriteResponse(_ result: [String: Any], expectedFile: URL) throws {
        guard let status = result["status"] as? String,
              status == "ok" || status == "okOverridden",
              let version = result["version"] as? String, !version.isEmpty,
              let filePath = result["filePath"] as? String,
              filePath == expectedFile.standardized.path
        else {
            throw CodexHookGateError.invalidManagedConfig(
                "config/batchWrite returned an invalid status, version, or managed file path."
            )
        }
    }
}

struct CodexHookInventoryDiagnostic: Equatable {
    let cwds: [String]
    let hookCount: Int
    let warningCount: Int
    let reviewRequiredCount: Int

    var isZeroInventory: Bool {
        hookCount == 0
    }
}

struct CodexHookLifecycleDiagnostic: Equatable {
    enum Status: String, Codable { case running, completed, failed, blocked, stopped }
    enum ExecutionMode: String, Codable { case sync, async }
    enum Scope: String, Codable { case thread, turn }
    enum EntryKind: String, Codable { case warning, stop, feedback, context, error }
    struct Entry: Codable, Equatable { let kind: EntryKind
        let text: String
    }

    struct Run: Decodable, Equatable {
        let id: String
        let eventName: CodexHookInventory.EventName
        let handlerType: CodexHookInventory.HandlerType
        let executionMode: ExecutionMode
        let scope: Scope
        let sourcePath: String
        let source: CodexHookInventory.Source
        let displayOrder: Int64
        let status: Status
        let statusMessage: String?
        let startedAt: Int64
        let completedAt: Int64?
        let durationMs: Int64?
        let entries: [Entry]

        private enum CodingKeys: String, CodingKey {
            case id, eventName, handlerType, executionMode, scope, sourcePath, source
            case displayOrder, status, statusMessage, startedAt, completedAt, durationMs, entries
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            eventName = try values.decode(CodexHookInventory.EventName.self, forKey: .eventName)
            handlerType = try values.decode(CodexHookInventory.HandlerType.self, forKey: .handlerType)
            executionMode = try values.decode(ExecutionMode.self, forKey: .executionMode)
            scope = try values.decode(Scope.self, forKey: .scope)
            sourcePath = try values.decode(String.self, forKey: .sourcePath)
            source = try values.decodeIfPresent(CodexHookInventory.Source.self, forKey: .source) ?? .unknown
            displayOrder = try values.decode(Int64.self, forKey: .displayOrder)
            status = try values.decode(Status.self, forKey: .status)
            statusMessage = try values.decodeIfPresent(String.self, forKey: .statusMessage)
            startedAt = try values.decode(Int64.self, forKey: .startedAt)
            completedAt = try values.decodeIfPresent(Int64.self, forKey: .completedAt)
            durationMs = try values.decodeIfPresent(Int64.self, forKey: .durationMs)
            entries = try values.decode([Entry].self, forKey: .entries)
        }
    }

    private struct Payload: Decodable {
        let threadId: String
        let turnId: String?
        let run: Run
    }

    let method: String
    let threadID: String
    let turnID: String?
    let run: Run

    var runID: String {
        run.id
    }

    var eventName: CodexHookInventory.EventName {
        run.eventName
    }

    var handlerType: CodexHookInventory.HandlerType {
        run.handlerType
    }

    var sourcePath: String {
        run.sourcePath
    }

    var status: Status {
        run.status
    }

    var statusMessage: String? {
        run.statusMessage
    }

    var reportedRuntimeFailure: Bool {
        status == .failed || status == .blocked || status == .stopped
    }

    static func decode(method: String, params: [String: Any]) throws -> CodexHookLifecycleDiagnostic {
        guard method == "hook/started" || method == "hook/completed",
              JSONSerialization.isValidJSONObject(params)
        else { throw CodexHookGateError.malformedInventory("Invalid hook lifecycle notification method or payload.") }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(
                Payload.self,
                from: JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
            )
        } catch {
            throw CodexHookGateError.malformedInventory("Hook lifecycle notification did not match the pinned Codex 0.147 schema.")
        }
        let normalizedSourcePath = URL(fileURLWithPath: payload.run.sourcePath).standardized.path
        guard !payload.threadId.isEmpty,
              !payload.threadId.utf8.contains(0),
              !payload.run.id.isEmpty,
              !payload.run.id.utf8.contains(0),
              payload.run.sourcePath.hasPrefix("/"),
              payload.run.sourcePath == normalizedSourcePath,
              !payload.run.sourcePath.utf8.contains(0)
        else {
            throw CodexHookGateError.malformedInventory("Hook lifecycle notification contained an invalid identity or path.")
        }
        guard (method == "hook/started" && payload.run.status == .running)
            || (method == "hook/completed" && payload.run.status != .running)
        else {
            throw CodexHookGateError.malformedInventory("Hook lifecycle notification contained an invalid method/status pairing.")
        }
        return .init(
            method: method,
            threadID: payload.threadId,
            turnID: payload.turnId,
            run: payload.run
        )
    }
}
