import CryptoKit
import Foundation
import RepoPromptSecureStorage

struct TipHistoryRepository: Equatable {
    let path: String

    init?(feedURL: URL?) {
        guard let feedURL, Self.isPlainGitHubURL(feedURL), !feedURL.absoluteString.contains("%") else { return nil }
        let components = feedURL.pathComponents
        guard components.count >= 5, components[3] == "releases",
              Self.matches(components[1], #"^[A-Za-z0-9_.-]+$"#),
              Self.matches(components[2], #"^[A-Za-z0-9_.-]+$"#)
        else { return nil }
        path = components[1] + "/" + components[2]
    }

    var headURL: URL {
        URL(string: "https://github.com/\(path)/releases/latest/download/tip-history.json")!
    }

    var releasesIndexURL: URL {
        URL(string: "https://github.com/\(path)/releases")!
    }

    func historyPageURL(tag: String) -> URL? {
        guard Self.validTag(tag) else { return nil }
        return URL(string: "https://github.com/\(path)/releases/download/\(tag)/tip-history.json")
    }

    func releasePageURL(tag: String) -> URL? {
        guard Self.validTag(tag) else { return nil }
        return URL(string: "https://github.com/\(path)/releases/tag/\(tag)")
    }

    func trustsDownload(_ url: URL, tag: String, name: String) -> Bool {
        guard Self.validTag(tag), Self.isPlainGitHubURL(url),
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("%"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return url.absoluteString == URL(string: "https://github.com/\(path)/releases/download/\(tag)/")?.appendingPathComponent(name).absoluteString
    }

    static func validTag(_ tag: String) -> Bool {
        matches(tag, #"^tip-[0-9a-f]{12}$"#)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return false }
        return range == text.startIndex ..< text.endIndex
    }

    private static func isPlainGitHubURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
            url.port == nil && url.query == nil && url.fragment == nil
    }
}

enum TipHistoryLoadError: Error, Equatable {
    case network, timeout, httpStatus(Int), notPublishedYet, unsupportedFormat, invalidSignature
    case integrityMismatch, malformed, olderPageUnavailable

    var message: String {
        switch self {
        case .network: "Couldn’t load history. Check your connection and try again."
        case .timeout: "The history request timed out."
        case let .httpStatus(status): "The release server returned HTTP \(status). Try again later."
        case .notPublishedYet: "History isn’t available yet for Tip builds."
        case .unsupportedFormat: "Update RepoPrompt CE to read newer history."
        case .invalidSignature: "The history signature could not be verified."
        case .integrityMismatch: "The release history failed its integrity check."
        case .malformed: "The release history contains invalid metadata."
        case .olderPageUnavailable: "This older history page is unavailable."
        }
    }
}

enum TipHistoryRole: String { case legacy, preparer, transition, successor, unknown }
enum TipHistorySigningIdentity: String { case legacy, successor, unknown }
enum TipHistoryInstallationType: String { case application, package, unknown }
enum TipHistoryEntryOrigin: String { case catalog, seed, githubRelease, unknown }
enum TipHistoryTextSource: String { case reviewed, commit }
enum TipHistoryMetadataProblem: String, Equatable {
    case identity = "Unknown or inconsistent signing identity"
    case constraints = "Invalid macOS or architecture constraints"
    case provenance = "Invalid release provenance"
    case download = "Invalid download metadata"
    case notes = "Invalid release notes"
}

struct TipHistoryCommitRange: Codable, Equatable { let fromCommit: String?
    let count: Int
}

struct TipHistoryNote: Equatable { let text: String
    let source: TipHistoryTextSource
}

struct TipHistoryPageReference: Codable, Equatable, Hashable { let tag: String
    let sha256: String
}

struct TipHistoryDownload: Equatable {
    let name: String
    let url: URL
    let size: Int64
    let expandedSize: Int64
    let sha256: String
    let edSignature: String
}

struct TipHistoryEntry: Equatable, Identifiable {
    var id: String {
        tag
    }

    let tag: String
    let releaseCommit: String
    let shortSHA: String
    let commitDate: Date?
    let buildNumber: String
    let build: SparkleBuildVersion
    let marketingVersion: String
    let hasHistoryUI: Bool
    let origin: TipHistoryEntryOrigin
    let role: TipHistoryRole
    let signingIdentity: TipHistorySigningIdentity
    let bundleIdentifier: String
    let teamIdentifier: String
    let migrationPhase: String
    let installationType: TipHistoryInstallationType
    let minimumSystemVersion: SparkleBuildVersion?
    let minimumSystemVersionString: String
    let commitRange: TipHistoryCommitRange?
    let architectures: Set<String>
    let title: String
    let titleSource: TipHistoryTextSource
    let notes: [TipHistoryNote]
    let omittedNoteCount: Int
    let downgradeBarrier: Bool
    let downgradeBarrierReasons: [String]
    let download: TipHistoryDownload?
    let metadataProblem: TipHistoryMetadataProblem?
    var historyCatalogSha256: String?

    func matchesImmutableFields(of other: Self) -> Bool {
        var left = self
        var right = other
        left.historyCatalogSha256 = nil
        right.historyCatalogSha256 = nil
        return left == right
    }
}

struct TipHistoryPage: Equatable {
    let generatedForTag: String
    let entries: [TipHistoryEntry]
    let olderPage: TipHistoryPageReference?
}

enum TipHistorySignatureVerifier {
    static func isValid(signatureBase64: String, message: Data, publicKeyBase64: String) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              let bytes = Data(base64Encoded: publicKeyBase64), bytes.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum TipHistoryCatalogDecoder {
    static let maximumEnvelopeSize = 1_048_576
    static let domain = Data("repoprompt-tip-history-v1\n".utf8)

    static func sanitize(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.filter {
            let value = $0.value
            return value >= 32 && !(127 ... 159).contains(value) &&
                !(0x202A ... 0x202E).contains(value) && !(0x2066 ... 0x2069).contains(value)
        }
        let clean = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
        return String(clean.prefix(limit))
    }

    static func decodePage(
        envelopeData: Data, expectedTag: String?, expectedSHA256: String?,
        publicKeyBase64: String, repository: TipHistoryRepository
    ) throws -> TipHistoryPage {
        guard envelopeData.count <= maximumEnvelopeSize else { throw TipHistoryLoadError.malformed }
        if let expectedSHA256, TipHistorySignatureVerifier.sha256(envelopeData) != expectedSHA256 {
            throw TipHistoryLoadError.integrityMismatch
        }
        do {
            try UniqueJSONKeys.validate(envelopeData)
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(Envelope.self, from: envelopeData)
            guard envelope.format == "repoprompt-tip-history", envelope.schemaVersion == 1 else {
                throw TipHistoryLoadError.unsupportedFormat
            }
            guard let payload = Data(base64Encoded: envelope.payload), payload.count <= maximumEnvelopeSize else {
                throw TipHistoryLoadError.malformed
            }
            guard TipHistorySignatureVerifier.isValid(signatureBase64: envelope.signature, message: domain + payload, publicKeyBase64: publicKeyBase64) else {
                throw TipHistoryLoadError.invalidSignature
            }
            try UniqueJSONKeys.validate(payload)
            let wire = try decoder.decode(Page.self, from: payload)
            guard wire.schemaVersion == 1 else { throw TipHistoryLoadError.unsupportedFormat }
            guard wire.channel == "tip", wire.updateRepository == repository.path, wire.windowSize == 30,
                  (1 ... 30).contains(wire.entries.count),
                  wire.generatedForTag == wire.entries.first?.tag,
                  expectedTag == nil || wire.generatedForTag == expectedTag
            else { throw TipHistoryLoadError.malformed }
            var entries: [TipHistoryEntry] = []
            var tags = Set<String>()
            for raw in wire.entries {
                guard let tag = raw.tag, tags.insert(tag).inserted,
                      let buildNumber = raw.buildNumber, let build = SparkleBuildVersion(buildNumber),
                      entries.last.map({ build < $0.build }) ?? true
                else { throw TipHistoryLoadError.malformed }
                entries.append(raw.validated(build: build, repository: repository))
            }
            for reference in [wire.olderPage, wire.archiveTail].compactMap(\.self) {
                guard TipHistoryRepository.validTag(reference.tag), TipHistoryRepository.matches(reference.sha256, #"^[0-9a-f]{64}$"#) else {
                    throw TipHistoryLoadError.malformed
                }
            }
            guard entries[0].historyCatalogSha256 == nil else { throw TipHistoryLoadError.integrityMismatch }
            if let older = wire.olderPage, let tail = entries.last {
                let direct = tail.historyCatalogSha256.map { TipHistoryPageReference(tag: tail.tag, sha256: $0) }
                // Seed records have no individual catalogs. Their only allowed
                // alternate edge is the retained, hash-bound bootstrap catalog.
                let seedAnchor = tail.origin == .seed && wire.archiveTail == older && entries.contains {
                    $0.origin == .catalog && $0.tag == older.tag && $0.historyCatalogSha256 == older.sha256
                }
                guard direct == older || seedAnchor else { throw TipHistoryLoadError.integrityMismatch }
            }
            return TipHistoryPage(generatedForTag: wire.generatedForTag, entries: entries, olderPage: wire.olderPage)
        } catch let error as TipHistoryLoadError {
            throw error
        } catch {
            throw TipHistoryLoadError.malformed
        }
    }

    /// JSONDecoder may choose one occurrence of a duplicate member. Reject that
    /// ambiguity, including in unknown additive fields, before decoding either
    /// document. Key literals are unescaped by Foundation so `a` and `\u0061`
    /// cannot become different authorities for the same field.
    private struct UniqueJSONKeys {
        private static let maximumDepth = 64
        private let bytes: [UInt8]
        private var position = 0

        static func validate(_ data: Data) throws {
            var scanner = Self(bytes: Array(data))
            try scanner.readValue(depth: 0)
            scanner.skipWhitespace()
            guard scanner.position == scanner.bytes.count else { throw TipHistoryLoadError.malformed }
        }

        private mutating func readValue(depth: Int) throws {
            skipWhitespace()
            guard position < bytes.count else { throw TipHistoryLoadError.malformed }
            switch bytes[position] {
            case 123: // {
                guard depth < Self.maximumDepth else { throw TipHistoryLoadError.malformed }
                try readObject(depth: depth)
            case 91: // [
                guard depth < Self.maximumDepth else { throw TipHistoryLoadError.malformed }
                try readArray(depth: depth)
            case 34:
                _ = try readString()
            case 116:
                try readLiteral("true")
            case 102:
                try readLiteral("false")
            case 110:
                try readLiteral("null")
            default:
                try readNumber()
            }
        }

        private mutating func readObject(depth: Int) throws {
            try require(123)
            skipWhitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                skipWhitespace()
                let range = try readString()
                guard let key = try JSONSerialization.jsonObject(with: Data(bytes[range]), options: [.fragmentsAllowed]) as? String,
                      keys.insert(key).inserted
                else { throw TipHistoryLoadError.malformed }
                skipWhitespace()
                try require(58) // :
                try readValue(depth: depth + 1)
                skipWhitespace()
                if consume(125) { return }
                try require(44) // ,
            }
        }

        private mutating func readArray(depth: Int) throws {
            try require(91)
            skipWhitespace()
            if consume(93) { return }
            while true {
                try readValue(depth: depth + 1)
                skipWhitespace()
                if consume(93) { return }
                try require(44)
            }
        }

        private mutating func readString() throws -> Range<Int> {
            let start = position
            try require(34)
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 34 { return start ..< position }
                guard byte >= 32 else { throw TipHistoryLoadError.malformed }
                if byte == 92 { // backslash
                    guard position < bytes.count else { throw TipHistoryLoadError.malformed }
                    let escape = bytes[position]
                    position += 1
                    if escape == 117 { // u + four hexadecimal digits
                        guard bytes.count - position >= 4 else { throw TipHistoryLoadError.malformed }
                        for offset in 0 ..< 4 {
                            let hex = bytes[position + offset]
                            guard (48 ... 57).contains(hex) || (65 ... 70).contains(hex) || (97 ... 102).contains(hex) else {
                                throw TipHistoryLoadError.malformed
                            }
                        }
                        position += 4
                    } else {
                        guard [34, 92, 47, 98, 102, 110, 114, 116].contains(escape) else { throw TipHistoryLoadError.malformed }
                    }
                }
            }
            throw TipHistoryLoadError.malformed
        }

        private mutating func readNumber() throws {
            _ = consume(45) // -
            if !consume(48) {
                guard position < bytes.count, (49 ... 57).contains(bytes[position]) else { throw TipHistoryLoadError.malformed }
                try readDigits()
            }
            if consume(46) { try readDigits() } // .
            if consume(101) || consume(69) { // e/E
                _ = consume(43) || consume(45)
                try readDigits()
            }
        }

        private mutating func readDigits() throws {
            let start = position
            while position < bytes.count, (48 ... 57).contains(bytes[position]) {
                position += 1
            }
            guard position > start else { throw TipHistoryLoadError.malformed }
        }

        private mutating func readLiteral(_ literal: String) throws {
            for byte in literal.utf8 {
                try require(byte)
            }
        }

        private mutating func skipWhitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) {
                position += 1
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        private mutating func require(_ byte: UInt8) throws {
            guard consume(byte) else { throw TipHistoryLoadError.malformed }
        }
    }

    private struct Envelope: Decodable { let format: String
        let schemaVersion: Int
        let payload: String
        let signature: String
    }

    private struct Page: Decodable {
        let schemaVersion: Int
        let channel: String
        let updateRepository: String
        let generatedForTag: String
        let windowSize: Int
        let entries: [Entry]
        let olderPage: TipHistoryPageReference?
        let archiveTail: TipHistoryPageReference?
    }

    /// Keep raw values and tolerate entry-level type failures so one bad record
    /// becomes a disabled row, not an apparently missing history page.
    private struct Entry: Decodable {
        let tag, releaseCommit, shortSHA, commitDate, buildNumber, marketingVersion: String?
        let role, signingIdentity, bundleIdentifier, teamIdentifier, migrationPhase, installationType: String?
        let minimumSystemVersion, title, titleSource, origin, historyCatalogSha256: String?
        let architectures: [String]?
        let notes: [Note]?
        let omittedCount: Int?
        let hasHistoryUI, downgradeBarrier: Bool?
        let downgradeBarrierReasons: [String]?
        let download: Download?
        let commitRange: TipHistoryCommitRange?
        let malformedOptionalFields: Bool

        private enum CodingKeys: String, CodingKey {
            case tag, releaseCommit, shortSHA, commitDate, buildNumber, marketingVersion, role, signingIdentity
            case bundleIdentifier, teamIdentifier, migrationPhase, installationType, minimumSystemVersion, title, titleSource
            case origin, historyCatalogSha256, architectures, notes, omittedCount, hasHistoryUI, downgradeBarrier
            case downgradeBarrierReasons, download, commitRange
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func string(_ key: CodingKeys) -> String? {
                try? c.decode(String.self, forKey: key)
            }
            tag = string(.tag)
            releaseCommit = string(.releaseCommit)
            shortSHA = string(.shortSHA)
            commitDate = string(.commitDate)
            buildNumber = string(.buildNumber)
            marketingVersion = string(.marketingVersion)
            role = string(.role)
            signingIdentity = string(.signingIdentity)
            bundleIdentifier = string(.bundleIdentifier)
            teamIdentifier = string(.teamIdentifier)
            migrationPhase = string(.migrationPhase)
            installationType = string(.installationType)
            minimumSystemVersion = string(.minimumSystemVersion)
            title = string(.title)
            titleSource = string(.titleSource)
            origin = string(.origin)
            historyCatalogSha256 = string(.historyCatalogSha256)
            architectures = try? c.decode([String].self, forKey: .architectures)
            notes = try? c.decode([Note].self, forKey: .notes)
            omittedCount = try? c.decode(Int.self, forKey: .omittedCount)
            hasHistoryUI = try? c.decode(Bool.self, forKey: .hasHistoryUI)
            downgradeBarrier = try? c.decode(Bool.self, forKey: .downgradeBarrier)
            downgradeBarrierReasons = try? c.decode([String].self, forKey: .downgradeBarrierReasons)
            download = try? c.decode(Download.self, forKey: .download)
            commitRange = try? c.decode(TipHistoryCommitRange.self, forKey: .commitRange)
            malformedOptionalFields = (c.contains(.download) && (try? c.decodeNil(forKey: .download)) == false && download == nil) ||
                (c.contains(.historyCatalogSha256) && (try? c.decodeNil(forKey: .historyCatalogSha256)) == false && historyCatalogSha256 == nil)
        }

        func validated(build: SparkleBuildVersion, repository: TipHistoryRepository) -> TipHistoryEntry {
            var problem: TipHistoryMetadataProblem?
            let r = TipHistoryRole(rawValue: role ?? "") ?? .unknown
            let identity = TipHistorySigningIdentity(rawValue: signingIdentity ?? "") ?? .unknown
            let installation = TipHistoryInstallationType(rawValue: installationType ?? "") ?? .unknown
            let official = OfficialApplicationIdentity(rawValue: identity.rawValue)
            let expectedIdentity: TipHistorySigningIdentity = (r == .legacy || r == .preparer) ? .legacy : .successor
            if r == .unknown || identity != expectedIdentity || official?.bundleIdentifier != bundleIdentifier || official?.teamIdentifier != teamIdentifier || migrationPhase != (r == .preparer ? "legacy-preparer" : "disabled") {
                problem = .identity
            }
            let os = minimumSystemVersion.flatMap(SparkleBuildVersion.init)
            let arch = Set(architectures ?? [])
            if os == nil || arch.isEmpty || !arch.isSubset(of: ["arm64", "x86_64"]) { problem = .constraints }
            let date = commitDate.flatMap { ISO8601DateFormatter().date(from: $0) }
            if commitRange == nil || (commitRange?.count ?? -1) < 0 || (commitRange?.fromCommit.map { !TipHistoryRepository.matches($0, #"^[0-9a-f]{40}$"#) } ?? false) { problem = .provenance }
            let source = TipHistoryTextSource(rawValue: titleSource ?? "")
            let entryOrigin = TipHistoryEntryOrigin(rawValue: origin ?? "") ?? .unknown
            if !TipHistoryRepository.validTag(tag ?? "") || !TipHistoryRepository.matches(releaseCommit ?? "", #"^[0-9a-f]{40}$"#) || shortSHA != releaseCommit.map({ String($0.prefix(12)) }) || tag != shortSHA.map({ "tip-" + $0 }) || date == nil || sanitize(marketingVersion ?? "", limit: 40).isEmpty || (entryOrigin != .catalog && entryOrigin != .seed) || (entryOrigin == .seed && historyCatalogSha256 != nil) || hasHistoryUI == nil || (historyCatalogSha256.map { !TipHistoryRepository.matches($0, #"^[0-9a-f]{64}$"#) } ?? false) {
                problem = .provenance
            }
            let text = sanitize(title ?? "", limit: 90)
            if text.isEmpty || source == nil || notes == nil || (notes?.count ?? 0) > 10 || omittedCount == nil || (omittedCount ?? -1) < 0 || downgradeBarrier == nil || downgradeBarrierReasons == nil || (downgradeBarrierReasons?.count ?? 0) > 3 || (downgradeBarrier == true && downgradeBarrierReasons?.isEmpty != false) || (downgradeBarrier == false && downgradeBarrierReasons?.isEmpty == false) { problem = .notes }
            let projectedNotes = (notes ?? []).map { TipHistoryNote(text: sanitize($0.text, limit: 200), source: TipHistoryTextSource(rawValue: $0.source) ?? .commit) }
            if (notes ?? []).contains(where: { TipHistoryTextSource(rawValue: $0.source) == nil || sanitize($0.text, limit: 200).isEmpty }) { problem = .notes }
            var verifiedDownload: TipHistoryDownload?
            if let d = download, let url = URL(string: d.url), repository.trustsDownload(url, tag: tag ?? "", name: d.name),
               d.name.hasSuffix(".zip"), d.size > 0, d.size <= 2_147_483_648, d.expandedSize > 0, d.expandedSize <= 8_589_934_592,
               TipHistoryRepository.matches(d.sha256, #"^[0-9a-f]{64}$"#), Data(base64Encoded: d.edSignature)?.count == 64
            {
                verifiedDownload = TipHistoryDownload(name: d.name, url: url, size: d.size, expandedSize: d.expandedSize, sha256: d.sha256, edSignature: d.edSignature)
            }
            if malformedOptionalFields || installation == .unknown || (installation == .application && verifiedDownload == nil) || (installation == .package && (download != nil || r != .transition)) || (r == .transition && installation != .package) { problem = .download }
            return TipHistoryEntry(tag: tag ?? "", releaseCommit: releaseCommit ?? "", shortSHA: sanitize(shortSHA ?? "", limit: 12), commitDate: date, buildNumber: buildNumber ?? "", build: build, marketingVersion: sanitize(marketingVersion ?? "", limit: 40), hasHistoryUI: hasHistoryUI ?? false, origin: entryOrigin, role: r, signingIdentity: identity, bundleIdentifier: bundleIdentifier ?? "", teamIdentifier: teamIdentifier ?? "", migrationPhase: migrationPhase ?? "", installationType: installation, minimumSystemVersion: os, minimumSystemVersionString: sanitize(minimumSystemVersion ?? "", limit: 30), commitRange: commitRange, architectures: arch, title: text.isEmpty ? "Tip build \(buildNumber ?? "unknown")" : text, titleSource: source ?? .commit, notes: projectedNotes, omittedNoteCount: omittedCount ?? 0, downgradeBarrier: downgradeBarrier ?? true, downgradeBarrierReasons: (downgradeBarrierReasons ?? ["Safety metadata unavailable"]).map { sanitize($0, limit: 200) }, download: verifiedDownload, metadataProblem: problem, historyCatalogSha256: historyCatalogSha256)
        }
    }

    private struct Note: Decodable { let text: String
        let source: String
    }

    private struct Download: Decodable {
        let name, url, sha256, edSignature: String
        let size, expandedSize: Int64
    }
}
