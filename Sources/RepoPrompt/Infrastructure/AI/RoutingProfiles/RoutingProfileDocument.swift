import Foundation

/// Non-executable annotations. Neither this schema nor its resolver can publish targets.
struct RoutingProfileDocument: Decodable {
    struct Family: Decodable {
        let providerID: String
        let id: String
        let utilityTier: String?
        let summary: String?
        let rubric: String?
        let aliases: [String]
        let matchers: [Matcher]
    }

    struct Matcher: Decodable {
        enum Kind: String, Decodable { case versionedPrefix }
        let kind: Kind
        let prefix: String
    }

    struct Model: Decodable {
        let providerID: String
        let id: String
        let aliases: [String]
        let familyID: String?
        let utilityTier: String?
        let summary: String?
        let rubric: String?
        let price: DatedText?
        let evidenceIDs: [String]
    }

    struct DatedText: Decodable {
        let text: String
        let checkedAt: Date
        let expiresAt: Date?
    }

    struct Evidence: Decodable {
        let id: String
        let text: String
        let publisher: String
        let sourceURL: String?
        let checkedAt: Date
        let expiresAt: Date?
        let familyWide: Bool
    }

    struct Effort: Decodable {
        let id: String
        let aliases: [String]
        let description: String
    }

    let schemaVersion: Int
    /// Required for signed remote snapshots; absent in the bundled offline resource.
    let sequence: UInt64?
    let minimumResolverVersion: Int?
    let profileVersion: String
    let evidenceVersion: String
    let rubricVersion: String
    let issuedAt: Date
    let expiresAt: Date?
    let families: [Family]
    let models: [Model]
    let evidence: [Evidence]
    let efforts: [Effort]
}

enum RoutingProfileDecodeError: Error, Equatable {
    case malformedJSON
    case duplicateJSONKey(String)
    case unknownField(String)
    case invalidSchema(String)
    case duplicateIdentity(String)
    case invalidReference(String)
}

enum RoutingProfileDocumentDecoder {
    static let maximumBytes = 1_048_576

    static func decode(_ data: Data) throws -> RoutingProfileDocument {
        guard data.count <= maximumBytes else { throw RoutingProfileDecodeError.invalidSchema("oversized document") }
        try rejectDuplicateKeys(data)
        let root = try JSONSerialization.jsonObject(with: data)
        try validateFields(root)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: RoutingProfileDocument
        do { document = try decoder.decode(RoutingProfileDocument.self, from: data) }
        catch { throw RoutingProfileDecodeError.invalidSchema("invalid typed document") }
        try validate(document)
        return document
    }

    static func rejectDuplicateKeys(_ data: Data) throws {
        var scanner = DuplicateJSONKeyScanner(data)
        try scanner.validate()
    }

    private static func validateFields(_ root: Any) throws {
        func object(_ value: Any, allowed: Set<String>, at path: String) throws -> [String: Any] {
            guard let fields = value as? [String: Any] else { throw RoutingProfileDecodeError.invalidSchema(path) }
            if let unknown = fields.keys.first(where: { !allowed.contains($0) }) {
                throw RoutingProfileDecodeError.unknownField("\(path).\(unknown)")
            }
            return fields
        }
        let root = try object(root, allowed: ["schemaVersion", "sequence", "minimumResolverVersion", "profileVersion", "evidenceVersion", "rubricVersion", "issuedAt", "expiresAt", "families", "models", "evidence", "efforts"], at: "root")
        for (name, fields) in [
            ("families", Set(["providerID", "id", "utilityTier", "summary", "rubric", "aliases", "matchers"])),
            ("models", Set(["providerID", "id", "aliases", "familyID", "utilityTier", "summary", "rubric", "price", "evidenceIDs"])),
            ("evidence", Set(["id", "text", "publisher", "sourceURL", "checkedAt", "expiresAt", "familyWide"])),
            ("efforts", Set(["id", "aliases", "description"]))
        ] {
            guard let entries = root[name] as? [Any] else { throw RoutingProfileDecodeError.invalidSchema(name) }
            for (index, entry) in entries.enumerated() {
                let item = try object(entry, allowed: fields, at: "\(name)[\(index)]")
                if name == "families" {
                    guard let matchers = item["matchers"] as? [Any] else { throw RoutingProfileDecodeError.invalidSchema("matchers") }
                    for matcher in matchers {
                        _ = try object(matcher, allowed: ["kind", "prefix"], at: "matcher")
                    }
                }
                if name == "models", let price = item["price"], !(price is NSNull) {
                    _ = try object(price, allowed: ["text", "checkedAt", "expiresAt"], at: "price")
                }
            }
        }
    }

    private static func validate(_ document: RoutingProfileDocument) throws {
        guard document.schemaVersion == 1,
              (document.sequence.map { $0 > 0 } ?? true),
              (document.minimumResolverVersion.map { $0 > 0 } ?? true),
              validID(document.profileVersion), validID(document.evidenceVersion),
              validID(document.rubricVersion),
              document.expiresAt.map({ $0 > document.issuedAt }) ?? true,
              document.families.count + document.models.count <= 512,
              document.evidence.count <= 512, document.efforts.count <= 128
        else { throw RoutingProfileDecodeError.invalidSchema("header or count") }
        let annotationCount = document.families.reduce(0) { $0 + $1.aliases.count + $1.matchers.count }
            + document.models.reduce(0) { $0 + $1.aliases.count }
            + document.efforts.reduce(0) { $0 + $1.aliases.count }
        guard annotationCount <= 1024 else { throw RoutingProfileDecodeError.invalidSchema("alias/matcher count") }
        var families: Set<String> = []
        var aliases: Set<String> = []
        for family in document.families {
            guard validID(family.providerID), validID(family.id),
                  [family.utilityTier, family.summary, family.rubric].compactMap(\.self).allSatisfy(validText),
                  families.insert("\(family.providerID):\(family.id)").inserted
            else { throw RoutingProfileDecodeError.duplicateIdentity("family \(family.providerID):\(family.id)") }
            var matchers: Set<String> = []
            for alias in family.aliases {
                guard validID(alias), aliases.insert("\(family.providerID):\(alias)").inserted
                else { throw RoutingProfileDecodeError.duplicateIdentity("alias \(alias)") }
            }
            for matcher in family.matchers {
                guard matcher.kind == .versionedPrefix,
                      matcher.prefix.hasSuffix("-"),
                      matcher.prefix.count > 2,
                      matcher.prefix.dropLast().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                      matchers.insert(matcher.prefix).inserted
                else { throw RoutingProfileDecodeError.invalidSchema("matcher") }
            }
        }
        var modelIDs: Set<String> = []
        for model in document.models {
            let key = "\(model.providerID):\(model.id)"
            guard validID(model.providerID), validID(model.id),
                  [model.utilityTier, model.summary, model.rubric, model.price?.text].compactMap(\.self).allSatisfy(validText),
                  modelIDs.insert(key).inserted
            else { throw RoutingProfileDecodeError.duplicateIdentity("model \(key)") }
            if let familyID = model.familyID, !families.contains("\(model.providerID):\(familyID)") {
                throw RoutingProfileDecodeError.invalidReference("family \(familyID)")
            }
            if let price = model.price, price.expiresAt.map({ $0 < price.checkedAt }) ?? false {
                throw RoutingProfileDecodeError.invalidSchema("price date")
            }
            for alias in model.aliases {
                guard validID(alias), alias != model.id,
                      aliases.insert("\(model.providerID):\(alias)").inserted,
                      !modelIDs.contains("\(model.providerID):\(alias)")
                else { throw RoutingProfileDecodeError.duplicateIdentity("alias \(alias)") }
            }
        }
        for alias in aliases where modelIDs.contains(alias) {
            throw RoutingProfileDecodeError.duplicateIdentity("alias \(alias)")
        }
        let evidenceIDs = Set(document.evidence.map(\.id))
        guard evidenceIDs.count == document.evidence.count,
              document.evidence.allSatisfy({ evidence in
                  validID(evidence.id) && validText(evidence.text) && validText(evidence.publisher)
                      && (evidence.sourceURL.map(validEvidenceURL) ?? true)
                      && (evidence.expiresAt.map { $0 >= evidence.checkedAt } ?? true)
              })
        else { throw RoutingProfileDecodeError.invalidSchema("evidence") }
        for model in document.models {
            guard Set(model.evidenceIDs).count == model.evidenceIDs.count else {
                throw RoutingProfileDecodeError.duplicateIdentity("evidence reference on \(model.id)")
            }
            guard Set(model.evidenceIDs).isSubset(of: evidenceIDs) else {
                throw RoutingProfileDecodeError.invalidReference("evidence on \(model.id)")
            }
        }
        var effortIDs: Set<String> = []
        for effort in document.efforts {
            guard validID(effort.id), validText(effort.description) else { throw RoutingProfileDecodeError.invalidSchema("effort") }
            for id in [effort.id] + effort.aliases {
                guard validID(id), effortIDs.insert(id).inserted
                else { throw RoutingProfileDecodeError.duplicateIdentity("effort \(id)") }
            }
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192
    }

    private static func validEvidenceURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.scheme == "https" && components.host?.isEmpty == false
            && components.user == nil && components.password == nil
    }
}

/// Scans object keys before JSONSerialization/JSONDecoder can collapse duplicates.
private struct DuplicateJSONKeyScanner {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        try value()
        whitespace()
        guard index == bytes.count else { throw RoutingProfileDecodeError.malformedJSON }
    }

    private mutating func value() throws {
        whitespace()
        guard index < bytes.count, depth < 64 else { throw RoutingProfileDecodeError.malformedJSON }
        switch bytes[index] {
        case 123: try object()
        case 91: try array()
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[index]) {
                index += 1
            }
            guard index > start else { throw RoutingProfileDecodeError.malformedJSON }
        }
    }

    private mutating func object() throws {
        depth += 1
        defer { depth -= 1 }
        index += 1
        whitespace()
        if consume(125) { return }
        var keys: Set<String> = []
        while true {
            whitespace()
            let key = try string()
            guard keys.insert(key).inserted else { throw RoutingProfileDecodeError.duplicateJSONKey(key) }
            whitespace()
            guard consume(58) else { throw RoutingProfileDecodeError.malformedJSON }
            try value()
            whitespace()
            if consume(125) { return }
            guard consume(44) else { throw RoutingProfileDecodeError.malformedJSON }
        }
    }

    private mutating func array() throws {
        depth += 1
        defer { depth -= 1 }
        index += 1
        whitespace()
        if consume(93) { return }
        while true {
            try value()
            whitespace()
            if consume(93) { return }
            guard consume(44) else { throw RoutingProfileDecodeError.malformedJSON }
        }
    }

    private mutating func string() throws -> String {
        guard consume(34) else { throw RoutingProfileDecodeError.malformedJSON }
        let start = index - 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2
                continue
            }
            if bytes[index] == 34 {
                index += 1
                guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start ..< index])) else {
                    throw RoutingProfileDecodeError.malformedJSON
                }
                return result
            }
            index += 1
        }
        throw RoutingProfileDecodeError.malformedJSON
    }

    private mutating func whitespace() {
        while index < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
