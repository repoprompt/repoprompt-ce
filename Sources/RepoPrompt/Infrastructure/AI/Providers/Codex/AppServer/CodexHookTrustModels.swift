import CryptoKit
import Foundation

struct CodexHookUTF8Identity: Hashable {
    let bytes: [UInt8]

    init(_ value: String) {
        bytes = Array(value.utf8)
    }

    func lexicographicallyPrecedes(_ other: Self) -> Bool {
        bytes.lexicographicallyPrecedes(other.bytes)
    }
}

struct CodexHookSelectionIdentity: Hashable {
    let key: CodexHookUTF8Identity
    let hash: CodexHookUTF8Identity
}

struct CodexHookInventoryIdentity: Hashable {
    let executionCWD: CodexHookUTF8Identity
    let hooks: [CodexHookMetadataIdentity]
    let warnings: [CodexHookUTF8Identity]
}

struct CodexHookMetadataIdentity: Hashable {
    let eventName: CodexHookUTF8Identity
    let source: CodexHookUTF8Identity
    let sourcePath: CodexHookUTF8Identity
    let selection: CodexHookSelectionIdentity
    let enabled: Bool
    let handlerType: CodexHookUTF8Identity
    let trustStatus: CodexHookTrustStatus
    let commandOrHandler: CodexHookUTF8Identity?
}

enum CodexHookTrustStatus: String, Hashable {
    case managed
    case untrusted
    case trusted
    case modified

    init(protocolValue: String) throws {
        guard let value = Self(rawValue: protocolValue) else {
            throw CodexHookTrustError.malformedListResponse
        }
        self = value
    }

    var isResolved: Bool {
        self == .trusted || self == .managed
    }
}

struct CodexHookMetadata: Hashable {
    let eventName: String
    let source: String
    let sourcePath: String
    let key: String
    let currentHash: String
    let enabled: Bool
    let handlerType: String
    let trustStatus: CodexHookTrustStatus
    let commandOrHandler: String?

    init(
        eventName: String,
        source: String,
        sourcePath: String,
        key: String,
        currentHash: String,
        enabled: Bool,
        handlerType: String,
        trustStatus: CodexHookTrustStatus,
        commandOrHandler: String?
    ) throws {
        guard !eventName.isBlank,
              !source.isBlank,
              !sourcePath.isBlank,
              !key.isBlank,
              !currentHash.isBlank,
              !handlerType.isBlank
        else {
            throw CodexHookTrustError.malformedListResponse
        }
        self.eventName = eventName
        self.source = source
        self.sourcePath = sourcePath
        self.key = key
        self.currentHash = currentHash
        self.enabled = enabled
        self.handlerType = handlerType
        self.trustStatus = trustStatus
        self.commandOrHandler = commandOrHandler
    }

    var keyIdentity: CodexHookUTF8Identity {
        CodexHookUTF8Identity(key)
    }

    var hashIdentity: CodexHookUTF8Identity {
        CodexHookUTF8Identity(currentHash)
    }

    var selectionIdentity: CodexHookSelectionIdentity {
        CodexHookSelectionIdentity(key: keyIdentity, hash: hashIdentity)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metadataIdentity == rhs.metadataIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(metadataIdentity)
    }

    var metadataIdentity: CodexHookMetadataIdentity {
        CodexHookMetadataIdentity(
            eventName: CodexHookUTF8Identity(eventName),
            source: CodexHookUTF8Identity(source),
            sourcePath: CodexHookUTF8Identity(sourcePath),
            selection: selectionIdentity,
            enabled: enabled,
            handlerType: CodexHookUTF8Identity(handlerType),
            trustStatus: trustStatus,
            commandOrHandler: commandOrHandler.map(CodexHookUTF8Identity.init)
        )
    }
}

struct CodexHookInventory: Hashable {
    let executionCWD: String
    let hooks: [CodexHookMetadata]
    let warnings: [String]

    init(
        executionCWD: String,
        hooks: [CodexHookMetadata],
        warnings: [String] = []
    ) throws {
        let standardizedCWD = Self.standardizedPath(executionCWD)
        guard !standardizedCWD.isBlank else {
            throw CodexHookTrustError.malformedListResponse
        }

        var uniqueHooks: [CodexHookMetadata] = []
        for hook in hooks {
            if let existing = uniqueHooks.first(where: { $0.key == hook.key }) {
                guard existing.keyIdentity == hook.keyIdentity,
                      existing.metadataIdentity == hook.metadataIdentity
                else {
                    throw CodexHookTrustError.malformedListResponse
                }
                continue
            }
            uniqueHooks.append(hook)
        }

        self.executionCWD = standardizedCWD
        self.hooks = uniqueHooks.sorted {
            if $0.keyIdentity == $1.keyIdentity {
                return $0.hashIdentity.lexicographicallyPrecedes($1.hashIdentity)
            }
            return $0.keyIdentity.lexicographicallyPrecedes($1.keyIdentity)
        }
        self.warnings = warnings
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inventoryIdentity == rhs.inventoryIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(inventoryIdentity)
    }

    var inventoryIdentity: CodexHookInventoryIdentity {
        CodexHookInventoryIdentity(
            executionCWD: CodexHookUTF8Identity(executionCWD),
            hooks: hooks.map(\.metadataIdentity),
            warnings: warnings.map(CodexHookUTF8Identity.init)
        )
    }

    var projectHooks: [CodexHookMetadata] {
        hooks.filter { $0.source == "project" }
    }

    var unresolvedProjectHooks: [CodexHookMetadata] {
        projectHooks.filter { !$0.trustStatus.isResolved }
    }

    func validatedUnresolvedProjectHooks(
        for candidates: [CodexHookTrustCandidate]
    ) -> [CodexHookMetadata]? {
        guard !candidates.isEmpty else { return nil }
        var selectedKeys = Set<CodexHookUTF8Identity>()
        var selectedHooks: [CodexHookMetadata] = []
        for candidate in candidates {
            guard candidate.isValid,
                  selectedKeys.insert(candidate.keyIdentity).inserted,
                  let hook = unresolvedProjectHooks.first(where: { $0.keyIdentity == candidate.keyIdentity }),
                  hook.hashIdentity == candidate.hashIdentity
            else {
                return nil
            }
            selectedHooks.append(hook)
        }
        return selectedHooks
    }

    func verifies(_ candidates: [CodexHookTrustCandidate]) -> Bool {
        candidates.allSatisfy { candidate in
            hooks.contains {
                $0.selectionIdentity == candidate.selectionIdentity && $0.trustStatus.isResolved
            }
        }
    }

    var fingerprint: String {
        var data = Data()
        Self.appendLengthPrefixed(executionCWD, to: &data)
        for hook in hooks {
            Self.appendLengthPrefixed(hook.key, to: &data)
            Self.appendLengthPrefixed(hook.currentHash, to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(result: [String: Any], executionCWD: String) throws -> Self {
        guard let entries = result["data"] as? [[String: Any]] else {
            throw CodexHookTrustError.malformedListResponse
        }

        let standardizedExpectedCWD = standardizedPath(executionCWD)
        let matchingEntries = try entries.filter { entry in
            guard let cwd = entry["cwd"] as? String, !cwd.isBlank else {
                throw CodexHookTrustError.malformedListResponse
            }
            return standardizedPath(cwd) == standardizedExpectedCWD
        }
        guard matchingEntries.count == 1, entries.count == 1, let entry = matchingEntries.first,
              let rawHooks = entry["hooks"] as? [[String: Any]],
              let errors = entry["errors"] as? [String],
              let warnings = entry["warnings"] as? [String]
        else {
            throw CodexHookTrustError.malformedListResponse
        }

        guard errors.isEmpty else {
            throw CodexHookTrustError.discoveryFailed(cwdErrors: errors)
        }
        let hooks = try rawHooks.map(Self.decodeHook)
        return try Self(
            executionCWD: standardizedExpectedCWD,
            hooks: hooks,
            warnings: warnings
        )
    }

    private static func decodeHook(_ raw: [String: Any]) throws -> CodexHookMetadata {
        guard let eventName = raw["eventName"] as? String,
              let source = raw["source"] as? String,
              let sourcePath = raw["sourcePath"] as? String,
              let key = raw["key"] as? String,
              let currentHash = raw["currentHash"] as? String,
              let enabled = raw["enabled"] as? Bool,
              let rawTrustStatus = raw["trustStatus"] as? String,
              let handlerType = raw["handlerType"] as? String
        else {
            throw CodexHookTrustError.malformedListResponse
        }

        let command: String?
        if let rawCommand = raw["command"] {
            if rawCommand is NSNull {
                command = nil
            } else if let rawCommand = rawCommand as? String {
                command = rawCommand
            } else {
                throw CodexHookTrustError.malformedListResponse
            }
        } else {
            command = nil
        }

        return try CodexHookMetadata(
            eventName: eventName,
            source: source,
            sourcePath: sourcePath,
            key: key,
            currentHash: currentHash,
            enabled: enabled,
            handlerType: handlerType,
            trustStatus: CodexHookTrustStatus(protocolValue: rawTrustStatus),
            commandOrHandler: command
        )
    }

    private static func standardizedPath(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}

struct CodexHookTrustCandidate: Hashable {
    let key: String
    let currentHash: String

    var keyIdentity: CodexHookUTF8Identity {
        CodexHookUTF8Identity(key)
    }

    var hashIdentity: CodexHookUTF8Identity {
        CodexHookUTF8Identity(currentHash)
    }

    var selectionIdentity: CodexHookSelectionIdentity {
        CodexHookSelectionIdentity(key: keyIdentity, hash: hashIdentity)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectionIdentity == rhs.selectionIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(selectionIdentity)
    }

    var isValid: Bool {
        !key.isBlank && !currentHash.isBlank
    }
}

enum CodexHookTrustError: Error, LocalizedError {
    case unsupportedMethod(method: String)
    case malformedListResponse
    case discoveryFailed(cwdErrors: [String])
    case inventoryChanged(replacement: CodexHookInventory)
    case batchWriteFailed
    case postWriteVerificationFailed(latest: CodexHookInventory?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unsupportedMethod(method):
            "Codex does not support the required \(method) hook-trust operation. Update Codex and retry."
        case .malformedListResponse:
            "Codex hook discovery returned an invalid result. Retry hook discovery."
        case let .discoveryFailed(cwdErrors):
            "Codex reported \(cwdErrors.count) hook discovery error(s). Review the project hook configuration and retry."
        case .inventoryChanged:
            "The project hook inventory changed before approval. Review the refreshed inventory and retry."
        case .batchWriteFailed:
            "Codex could not persist hook trust. Retry approval."
        case .postWriteVerificationFailed:
            "Codex could not verify hook trust after writing it. Review the current inventory and retry."
        case .cancelled:
            "The Codex hook-trust operation was cancelled. Retry when ready."
        }
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
