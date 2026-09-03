import Foundation

package enum DomainCommandOrigin: Codable, Equatable, Sendable {
    case appPresentation(windowID: Int)
    case appMCP(connectionID: UUID?)
    case standalone
    case externalReload
}

private extension DomainCommandOrigin {
    var fingerprintComponent: String {
        switch self {
        case let .appPresentation(windowID): "presentation:\(windowID)"
        case let .appMCP(connectionID): "app-mcp:\(connectionID?.uuidString ?? "nil")"
        case .standalone: "standalone"
        case .externalReload: "external-reload"
        }
    }
}

private struct DomainCanonicalJSONNumber {
    let isNegative: Bool
    let coefficient: String
    let exponent: String

    init?(_ token: ArraySlice<UInt8>) {
        let bytes = Array(token)
        var index = 0
        let negative = bytes.first == 0x2D
        if negative { index += 1 }

        let integerStart = index
        guard index < bytes.count else { return nil }
        if bytes[index] == 0x30 {
            index += 1
            guard index == bytes.count || !Self.isDigit(bytes[index]) else { return nil }
        } else {
            guard Self.isNonzeroDigit(bytes[index]) else { return nil }
            repeat { index += 1 } while index < bytes.count && Self.isDigit(bytes[index])
        }
        let integerEnd = index

        var fractionRange: Range<Int>?
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            let fractionStart = index
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            guard index > fractionStart else { return nil }
            fractionRange = fractionStart ..< index
        }

        var parsedExponent = DomainArbitrarySignedDecimal.zero
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            var exponentIsNegative = false
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                exponentIsNegative = bytes[index] == 0x2D
                index += 1
            }
            let exponentStart = index
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
            guard index > exponentStart else { return nil }
            parsedExponent = DomainArbitrarySignedDecimal(
                negative: exponentIsNegative,
                asciiDigits: bytes[exponentStart ..< index]
            )
        }
        guard index == bytes.count else { return nil }

        var coefficientDigits = Array(bytes[integerStart ..< integerEnd])
        let fractionCount = fractionRange?.count ?? 0
        if let fractionRange {
            coefficientDigits.append(contentsOf: bytes[fractionRange])
        }
        guard let firstNonzeroIndex = coefficientDigits.firstIndex(where: { $0 != 0x30 }) else {
            isNegative = false
            coefficient = "0"
            exponent = "0"
            return
        }
        coefficientDigits.removeFirst(firstNonzeroIndex)

        var trailingZeroCount = 0
        while coefficientDigits.last == 0x30 {
            coefficientDigits.removeLast()
            trailingZeroCount += 1
        }
        parsedExponent.add(magnitude: fractionCount, negative: true)
        parsedExponent.add(magnitude: trailingZeroCount, negative: false)

        isNegative = negative
        coefficient = String(decoding: coefficientDigits, as: UTF8.self)
        exponent = parsedExponent.description
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isNonzeroDigit(_ byte: UInt8) -> Bool {
        byte >= 0x31 && byte <= 0x39
    }
}

private struct DomainArbitrarySignedDecimal {
    static let zero = DomainArbitrarySignedDecimal(negative: false, asciiDigits: [0x30])

    private var isNegative: Bool
    private var digits: [UInt8]

    init(negative: Bool, asciiDigits: ArraySlice<UInt8>) {
        let normalized = asciiDigits.drop(while: { $0 == 0x30 }).map { $0 - 0x30 }
        if normalized.isEmpty {
            isNegative = false
            digits = [0]
        } else {
            isNegative = negative
            digits = normalized
        }
    }

    private init(negative: Bool, asciiDigits: [UInt8]) {
        self.init(negative: negative, asciiDigits: asciiDigits[...])
    }

    mutating func add(magnitude: Int, negative: Bool) {
        guard magnitude > 0 else { return }
        let other = String(magnitude).utf8.map { $0 - 0x30 }
        if isNegative == negative {
            digits = Self.addMagnitudes(digits, other)
            return
        }

        switch Self.compareMagnitudes(digits, other) {
        case 1:
            digits = Self.subtractMagnitudes(digits, other)
        case -1:
            digits = Self.subtractMagnitudes(other, digits)
            isNegative = negative
        default:
            digits = [0]
            isNegative = false
        }
    }

    var description: String {
        let magnitude = String(decoding: digits.map { $0 + 0x30 }, as: UTF8.self)
        return isNegative ? "-\(magnitude)" : magnitude
    }

    private static func compareMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? -1 : 1
        }
        return 0
    }

    private static func addMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var leftIndex = lhs.count - 1
        var rightIndex = rhs.count - 1
        var carry: UInt8 = 0
        while leftIndex >= 0 || rightIndex >= 0 || carry != 0 {
            let left = leftIndex >= 0 ? lhs[leftIndex] : 0
            let right = rightIndex >= 0 ? rhs[rightIndex] : 0
            let sum = left + right + carry
            result.append(sum % 10)
            carry = sum / 10
            leftIndex -= 1
            rightIndex -= 1
        }
        return Array(result.reversed())
    }

    private static func subtractMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var leftIndex = lhs.count - 1
        var rightIndex = rhs.count - 1
        var borrow = 0
        while leftIndex >= 0 {
            var difference = Int(lhs[leftIndex]) - borrow
            if rightIndex >= 0 { difference -= Int(rhs[rightIndex]) }
            if difference < 0 {
                difference += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt8(difference))
            leftIndex -= 1
            rightIndex -= 1
        }
        while result.count > 1, result.last == 0 { result.removeLast() }
        return Array(result.reversed())
    }
}

private indirect enum DomainCanonicalJSONValue {
    case null
    case bool(Bool)
    case number(DomainCanonicalJSONNumber)
    case string(String)
    case array([DomainCanonicalJSONValue])
    case object([String: DomainCanonicalJSONValue])

    func appendFingerprintComponents(to components: inout [String]) {
        switch self {
        case .null:
            components.append("null")
        case let .bool(value):
            components += ["bool", value ? "true" : "false"]
        case let .number(value):
            components += [
                "number",
                value.isNegative ? "negative" : "positive",
                value.coefficient,
                value.exponent
            ]
        case let .string(value):
            components += ["string", value]
        case let .array(values):
            components += ["array", String(values.count)]
            for value in values {
                value.appendFingerprintComponents(to: &components)
            }
        case let .object(values):
            components += ["object", String(values.count)]
            for key in values.keys.sorted() {
                components += ["key", key]
                values[key]?.appendFingerprintComponents(to: &components)
            }
        }
    }
}

private struct DomainCanonicalJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() -> DomainCanonicalJSONValue? {
        skipWhitespace()
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private mutating func parseValue() -> DomainCanonicalJSONValue? {
        guard index < bytes.count else { return nil }
        return switch bytes[index] {
        case 0x7B: parseObject()
        case 0x5B: parseArray()
        case 0x22: parseString().map(DomainCanonicalJSONValue.string)
        case 0x74: consumeLiteral("true") ? .bool(true) : nil
        case 0x66: consumeLiteral("false") ? .bool(false) : nil
        case 0x6E: consumeLiteral("null") ? .null : nil
        case 0x2D, 0x30 ... 0x39: parseNumber().map(DomainCanonicalJSONValue.number)
        default: nil
        }
    }

    private mutating func parseObject() -> DomainCanonicalJSONValue? {
        index += 1
        skipWhitespace()
        var values: [String: DomainCanonicalJSONValue] = [:]
        if consume(0x7D) { return .object(values) }
        while true {
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard consume(0x3A) else { return nil }
            skipWhitespace()
            guard let value = parseValue(), values[key] == nil else { return nil }
            values[key] = value
            skipWhitespace()
            if consume(0x7D) { return .object(values) }
            guard consume(0x2C) else { return nil }
            skipWhitespace()
        }
    }

    private mutating func parseArray() -> DomainCanonicalJSONValue? {
        index += 1
        skipWhitespace()
        var values: [DomainCanonicalJSONValue] = []
        if consume(0x5D) { return .array(values) }
        while true {
            guard let value = parseValue() else { return nil }
            values.append(value)
            skipWhitespace()
            if consume(0x5D) { return .array(values) }
            guard consume(0x2C) else { return nil }
            skipWhitespace()
        }
    }

    private mutating func parseString() -> String? {
        guard index < bytes.count, bytes[index] == 0x22 else { return nil }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if !escaped, byte == 0x22 {
                index += 1
                return try? JSONDecoder().decode(
                    String.self,
                    from: Data(bytes[start ..< index])
                )
            }
            if !escaped, byte < 0x20 { return nil }
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            }
            index += 1
        }
        return nil
    }

    private mutating func parseNumber() -> DomainCanonicalJSONNumber? {
        let start = index
        if consume(0x2D), index == bytes.count { return nil }
        if index < bytes.count, bytes[index] == 0x30 {
            index += 1
        } else {
            guard index < bytes.count, bytes[index] >= 0x31, bytes[index] <= 0x39 else { return nil }
            repeat { index += 1 } while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39
        }
        if consume(0x2E) {
            let fractionStart = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            guard index > fractionStart else { return nil }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            let exponentStart = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            guard index > exponentStart else { return nil }
        }
        return DomainCanonicalJSONNumber(bytes[start ..< index])
    }

    private mutating func consumeLiteral(_ literal: String) -> Bool {
        let literalBytes = Array(literal.utf8)
        guard bytes[index...].starts(with: literalBytes) else { return false }
        index += literalBytes.count
        return true
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D
        {
            index += 1
        }
    }
}

private extension DomainWorkspaceDocument {
    var semanticFingerprintIdentity: String {
        var parser = DomainCanonicalJSONParser(data: documentBytes)
        guard let value = parser.parse() else {
            return "invalid-json-bytes-v1:\(contentDigest)"
        }
        var components: [String] = []
        value.appendFingerprintComponents(to: &components)
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return "json-v1:\(DomainContentDigest.sha256(Data(canonical.utf8)))"
    }
}

package enum DomainWorkspaceCommand: Codable, Equatable, Sendable {
    case createWorkspace(DomainWorkspaceDocument)
    case resolveOrCreateWorkspaceForExactRoot(
        document: DomainWorkspaceDocument,
        canonicalRootPath: String
    )
    case replaceWorkingDocument(DomainWorkspaceDocument)
    case saveWorkspaceDocument(workspaceID: UUID)
    case deleteWorkspace(workspaceID: UUID)
    case resolveExternalConflict(
        workspaceID: UUID,
        acceptExternal: Bool,
        protectedAgentIdentities: [DomainProtectedAgentIdentity]
    )
}

/// Opt-in command behavior for mutations that must never replay their captured bytes over a
/// concurrent durable winner.
package enum DomainWorkspaceConflictRecoveryPolicy: String, Codable, Equatable, Sendable {
    case failClosed
}

package struct DomainWorkspaceCommandEnvelope: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let expectedCatalogRevision: UInt64?
    package let expectedWorkspaceRevision: UInt64?
    package let expectedContextRevision: UInt64?
    package let conflictRecoveryPolicy: DomainWorkspaceConflictRecoveryPolicy?
    package let origin: DomainCommandOrigin
    package let command: DomainWorkspaceCommand

    package init(
        operationID: UUID,
        expectedCatalogRevision: UInt64? = nil,
        expectedWorkspaceRevision: UInt64? = nil,
        expectedContextRevision: UInt64? = nil,
        conflictRecoveryPolicy: DomainWorkspaceConflictRecoveryPolicy? = nil,
        origin: DomainCommandOrigin,
        command: DomainWorkspaceCommand
    ) {
        self.operationID = operationID
        self.expectedCatalogRevision = expectedCatalogRevision
        self.expectedWorkspaceRevision = expectedWorkspaceRevision
        self.expectedContextRevision = expectedContextRevision
        self.conflictRecoveryPolicy = conflictRecoveryPolicy
        self.origin = origin
        self.command = command
    }

    package var documentIdentity: String? {
        switch command {
        case let .createWorkspace(document),
             let .resolveOrCreateWorkspaceForExactRoot(document, _),
             let .replaceWorkingDocument(document):
            document.semanticFingerprintIdentity
        case .saveWorkspaceDocument, .deleteWorkspace, .resolveExternalConflict:
            nil
        }
    }

    package var fingerprint: String {
        fingerprint { $0.semanticFingerprintIdentity }
    }

    /// Fingerprints persisted before semantic document identity was introduced hashed the raw
    /// document bytes. Keep computing that exact value so existing operation records still replay.
    package var legacyFingerprint: String {
        fingerprint { $0.contentDigest }
    }

    package func matchesRecordedFingerprint(
        _ recordedFingerprint: String,
        canonicalFingerprint: String
    ) -> Bool {
        recordedFingerprint == canonicalFingerprint || recordedFingerprint == legacyFingerprint
    }

    private func fingerprint(
        documentIdentity: (DomainWorkspaceDocument) -> String
    ) -> String {
        var components = [
            operationID.uuidString,
            expectedCatalogRevision.map(String.init) ?? "nil",
            expectedWorkspaceRevision.map(String.init) ?? "nil",
            expectedContextRevision.map(String.init) ?? "nil",
            origin.fingerprintComponent
        ]
        if let conflictRecoveryPolicy {
            components.append("conflict-recovery:\(conflictRecoveryPolicy.rawValue)")
        }
        switch command {
        case let .createWorkspace(document):
            components += ["create", document.workspaceID.uuidString, document.fileURL.absoluteString, documentIdentity(document)]
        case let .resolveOrCreateWorkspaceForExactRoot(document, canonicalRootPath):
            components += [
                "resolve-or-create-exact-root",
                document.workspaceID.uuidString,
                document.fileURL.absoluteString,
                documentIdentity(document),
                canonicalRootPath
            ]
        case let .replaceWorkingDocument(document):
            components += ["replace", document.workspaceID.uuidString, document.fileURL.absoluteString, documentIdentity(document)]
        case let .saveWorkspaceDocument(workspaceID):
            components += ["save", workspaceID.uuidString]
        case let .deleteWorkspace(workspaceID):
            components += ["delete", workspaceID.uuidString]
        case let .resolveExternalConflict(workspaceID, acceptExternal, protectedAgentIdentities):
            components += ["resolve", workspaceID.uuidString, acceptExternal ? "external" : "local"]
            components += protectedAgentIdentities
                .sorted {
                    if $0.location.rawValue != $1.location.rawValue {
                        return $0.location.rawValue < $1.location.rawValue
                    }
                    return $0.tabID.uuidString < $1.tabID.uuidString
                }
                .flatMap {
                    [
                        $0.location.rawValue,
                        $0.tabID.uuidString,
                        $0.activeAgentSessionID?.uuidString ?? "nil",
                        $0.isPinned ? "pinned" : "unpinned"
                    ]
                }
        }
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return DomainContentDigest.sha256(Data(canonical.utf8))
    }
}

package enum DomainCommandDisposition: String, Codable, Sendable {
    case applied
    case unchanged
    case conflict
    case readOnly
    case invalid
    case failed
    case deduplicated
}

package enum DomainCommandErrorCode: String, Codable, Sendable {
    case stateConflict = "state_conflict"
    case runtimeReadOnlyDegraded = "runtime_read_only_degraded"
    case workspaceExternalConflict = "workspace_external_conflict"
    case workspaceReadOnlyDegraded = "workspace_read_only_degraded"
    case protectedAgentIdentityConflict = "protected_agent_identity_conflict"
    case operationIDCollision = "operation_id_collision"
    case workspaceUnavailable = "workspace_unavailable"
    case invalidDocument = "invalid_document"
    case persistenceFailure = "persistence_failure"
    case lockTimedOut = "lock_timed_out"
    case cancelled
}

package struct DomainCommandOutcome: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let disposition: DomainCommandDisposition
    package let before: DomainRevisionState?
    package let after: DomainRevisionState?
    package let catalogRevision: UInt64
    package let resultingDigest: String?
    package let errorCode: DomainCommandErrorCode?
    package let diagnostic: String?
    package let workspace: DomainWorkspaceSnapshot?

    package init(
        operationID: UUID,
        disposition: DomainCommandDisposition,
        before: DomainRevisionState?,
        after: DomainRevisionState?,
        catalogRevision: UInt64,
        resultingDigest: String?,
        errorCode: DomainCommandErrorCode? = nil,
        diagnostic: String? = nil,
        workspace: DomainWorkspaceSnapshot? = nil
    ) {
        self.operationID = operationID
        self.disposition = disposition
        self.before = before
        self.after = after
        self.catalogRevision = catalogRevision
        self.resultingDigest = resultingDigest
        self.errorCode = errorCode
        self.diagnostic = diagnostic
        self.workspace = workspace
    }
}

struct DomainRecordedOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let fingerprint: String
    let recordedAt: Date
    let disposition: DomainCommandDisposition
    let before: DomainRevisionState?
    let after: DomainRevisionState?
    let catalogRevision: UInt64
    let resultingDigest: String?
    let resultingWorkspaceID: UUID?
    let errorCode: DomainCommandErrorCode?
    let diagnostic: String?

    init(
        fingerprint: String,
        recordedAt: Date,
        outcome: DomainCommandOutcome,
        resultingWorkspaceID: UUID? = nil
    ) {
        operationID = outcome.operationID
        self.fingerprint = fingerprint
        self.recordedAt = recordedAt
        disposition = outcome.disposition
        before = outcome.before
        after = outcome.after
        catalogRevision = outcome.catalogRevision
        resultingDigest = outcome.resultingDigest
        self.resultingWorkspaceID = resultingWorkspaceID ?? outcome.workspace?.document.workspaceID
        errorCode = outcome.errorCode
        diagnostic = outcome.diagnostic
    }

    func outcome(workspace: DomainWorkspaceSnapshot?) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: operationID,
            disposition: .deduplicated,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: resultingDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
    }
}
