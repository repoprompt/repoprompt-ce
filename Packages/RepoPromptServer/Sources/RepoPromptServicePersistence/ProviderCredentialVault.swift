import Crypto
import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct ProviderVaultKey: Sendable {
    public let keyID: String
    public let material: Data

    public init(keyID: String, material: Data) throws {
        guard keyID.range(of: "^[A-Za-z0-9_.:-]{1,128}$", options: .regularExpression) != nil else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider vault key identifier is invalid")
        }
        guard material.count == 32 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider vault master key must contain exactly 256 bits")
        }
        self.keyID = keyID
        self.material = material
    }

    public static func load(keyID: String, filePath: String) throws -> Self {
        try requirePrivateRegularFile(atPath: filePath, label: "Provider vault master key")
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let trimmed = Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let material: Data
        if data.count == 32 {
            material = data
        } else if let decoded = Data(base64Encoded: trimmed), decoded.count == 32 {
            material = decoded
        } else if trimmed.count == 64, let decoded = Self.decodeHex(String(decoding: trimmed, as: UTF8.self)) {
            material = decoded
        } else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault master key file is not raw, base64, or hexadecimal 256-bit material", retryable: false)
        }
        return try Self(keyID: keyID, material: material)
    }

    private static func requirePrivateRegularFile(atPath path: String, label: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "\(label) file must be a regular file", retryable: false)
        }
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "\(label) file must have mode 0600", retryable: false)
        }
        if let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value {
            guard owner == geteuid() else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "\(label) file must be owned by the service account", retryable: false)
            }
        }
    }

    private static func decodeHex(_ value: String) -> Data? {
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result.count == 32 ? result : nil
    }
}

/// AES-256-GCM vault stored separately from SQLite. The JSON document contains
/// ciphertext only and is atomically replaced with mode 0600.
public actor ProviderCredentialVault {
    private struct Entry: Codable {
        let providerID: String
        let connectionID: UUID
        let keyID: String
        let sealed: String
        let revision: Int64
        let updatedAt: Date
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var generation: Int64
        var entries: [String: Entry]
    }

    private struct LegacyDocument: Codable {
        let schemaVersion: Int
        let generation: Int64
        let entries: [String: String]
        let keyID: String
    }

    private let fileURL: URL
    private var keys: [String: SymmetricKey]
    private var activeKeyID: String
    private var document: Document
    private var persistencePoisoned = false

    public init(fileURL: URL, activeKey: ProviderVaultKey, decryptionKeys: [ProviderVaultKey] = []) throws {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider vault path must be absolute")
        }
        self.fileURL = fileURL
        activeKeyID = activeKey.keyID
        let allKeys = decryptionKeys + [activeKey]
        guard Set(allKeys.map(\.keyID)).count == allKeys.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider vault key identifiers must be unique")
        }
        keys = Dictionary(uniqueKeysWithValues: allKeys.map { ($0.keyID, SymmetricKey(data: $0.material)) })
        document = Document(schemaVersion: 2, generation: 0, entries: [:])
        try Self.prepareParent(of: fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try Self.requirePrivateFile(fileURL)
            let data = try Data(contentsOf: fileURL)
            if let current = try? JSONDecoder.serviceDecoder.decode(Document.self, from: data), current.schemaVersion == 2 {
                try Self.validate(current, keys: keys)
                document = current
            } else {
                let legacy = try JSONDecoder.serviceDecoder.decode(LegacyDocument.self, from: data)
                guard legacy.schemaVersion == 1, let key = keys[legacy.keyID] else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault schema or key is unavailable", retryable: false)
                }
                var migrated: [String: Entry] = [:]
                for (identifier, ciphertext) in legacy.entries {
                    guard let connectionID = UUID(uuidString: identifier), let combined = Data(base64Encoded: ciphertext) else {
                        throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault legacy entry is invalid", retryable: false)
                    }
                    let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
                    let payload = try JSONDecoder.serviceDecoder.decode(LegacyPayload.self, from: clear)
                    let sealed = try Self.seal(payload.secret, providerID: payload.providerID, connectionID: connectionID, keyID: activeKey.keyID, key: SymmetricKey(data: activeKey.material))
                    migrated[identifier] = Entry(providerID: payload.providerID.rawValue, connectionID: connectionID, keyID: activeKey.keyID, sealed: sealed.base64EncodedString(), revision: 1, updatedAt: Date())
                }
                document = Document(schemaVersion: 2, generation: legacy.generation + 1, entries: migrated)
                try Self.write(document, to: fileURL)
            }
        }
    }

    private struct LegacyPayload: Codable {
        let providerID: ProviderSettingsID
        let secret: Data
    }

    public func store(secret: Data, providerID: ProviderSettingsID, connectionID: UUID) throws {
        try requireUsable()
        guard !secret.isEmpty, secret.count <= 65536, let key = keys[activeKeyID] else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider credential is empty or exceeds the supported size")
        }
        let identifier = connectionID.uuidString
        let revision = (document.entries[identifier]?.revision ?? 0) + 1
        let sealed = try Self.seal(secret, providerID: providerID, connectionID: connectionID, keyID: activeKeyID, key: key)
        var next = document
        next.entries[identifier] = Entry(providerID: providerID.rawValue, connectionID: connectionID, keyID: activeKeyID, sealed: sealed.base64EncodedString(), revision: revision, updatedAt: Date())
        next.generation += 1
        try persist(next)
    }

    public func load(providerID: ProviderSettingsID, connectionID: UUID) throws -> Data {
        try requireUsable()
        guard let entry = document.entries[connectionID.uuidString], entry.providerID == providerID.rawValue,
              let key = keys[entry.keyID], let combined = Data(base64Encoded: entry.sealed)
        else { throw ServiceAPIError(code: .notFound, message: "Provider credential is not available") }
        return try AES.GCM.open(
            AES.GCM.SealedBox(combined: combined),
            using: key,
            authenticating: Self.aad(providerID: providerID, connectionID: connectionID, keyID: entry.keyID)
        )
    }

    public func delete(providerID: ProviderSettingsID, connectionID: UUID) throws {
        try requireUsable()
        if let entry = document.entries[connectionID.uuidString], entry.providerID != providerID.rawValue {
            throw ServiceAPIError(code: .notFound, message: "Provider credential is not available")
        }
        var next = document
        guard next.entries.removeValue(forKey: connectionID.uuidString) != nil else { return }
        next.generation += 1
        try persist(next)
    }

    public func rotate(to newKey: ProviderVaultKey) throws {
        try requireUsable()
        let newSymmetricKey = SymmetricKey(data: newKey.material)
        var rotated: [String: Entry] = [:]
        for entry in document.entries.values {
            guard let providerID = ProviderSettingsID(rawValue: entry.providerID) else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault contains an unknown provider", retryable: false)
            }
            let clear = try load(providerID: providerID, connectionID: entry.connectionID)
            let sealed = try Self.seal(clear, providerID: providerID, connectionID: entry.connectionID, keyID: newKey.keyID, key: newSymmetricKey)
            rotated[entry.connectionID.uuidString] = Entry(providerID: entry.providerID, connectionID: entry.connectionID, keyID: newKey.keyID, sealed: sealed.base64EncodedString(), revision: entry.revision + 1, updatedAt: Date())
        }
        var next = document
        next.entries = rotated
        next.generation += 1
        try persist(next)
        activeKeyID = newKey.keyID
        keys = [newKey.keyID: newSymmetricKey]
    }

    /// Re-encrypts entries that still reference a configured previous key and
    /// then retires every decryption-only key from process memory.
    public func rotateToActiveKeyIfNeeded() throws {
        try requireUsable()
        guard document.entries.values.contains(where: { $0.keyID != activeKeyID }) else {
            guard let active = keys[activeKeyID] else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault active key is unavailable", retryable: false)
            }
            keys = [activeKeyID: active]
            return
        }
        guard let active = keys[activeKeyID] else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault active key is unavailable", retryable: false)
        }
        var rotated: [String: Entry] = [:]
        for entry in document.entries.values {
            guard let providerID = ProviderSettingsID(rawValue: entry.providerID) else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault contains an unknown provider", retryable: false)
            }
            let clear = try load(providerID: providerID, connectionID: entry.connectionID)
            let sealed = try Self.seal(clear, providerID: providerID, connectionID: entry.connectionID, keyID: activeKeyID, key: active)
            rotated[entry.connectionID.uuidString] = Entry(
                providerID: entry.providerID,
                connectionID: entry.connectionID,
                keyID: activeKeyID,
                sealed: sealed.base64EncodedString(),
                revision: entry.revision + 1,
                updatedAt: Date()
            )
        }
        var next = document
        next.entries = rotated
        next.generation += 1
        try persist(next)
        keys = [activeKeyID: active]
    }

    /// Validates every durable SQLite reference and atomically removes vault
    /// entries left behind by a crash between the file and database commits.
    public func reconcile(references: [ProviderSettingsID: UUID]) throws {
        try requireUsable()
        for (providerID, reference) in references {
            guard document.entries[reference.uuidString]?.providerID == providerID.rawValue else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider connection references missing credential material", retryable: false)
            }
        }
        let expected = Set(references.values.map(\.uuidString))
        let extras = Set(document.entries.keys).subtracting(expected)
        guard !extras.isEmpty else { return }
        var next = document
        for identifier in extras {
            next.entries[identifier] = nil
        }
        next.generation += 1
        try persist(next)
    }

    public func contains(providerID: ProviderSettingsID, connectionID: UUID) -> Bool {
        !persistencePoisoned && document.entries[connectionID.uuidString]?.providerID == providerID.rawValue
    }

    private func requireUsable() throws {
        guard !persistencePoisoned else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider credential vault requires process restart after a durability failure", retryable: false)
        }
    }

    private func persist(_ next: Document) throws {
        do {
            try Self.write(next, to: fileURL)
            document = next
        } catch let error as PostReplacementWriteError {
            persistencePoisoned = true
            throw error.underlying
        }
    }

    private static func seal(_ secret: Data, providerID: ProviderSettingsID, connectionID: UUID, keyID: String, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(secret, using: key, authenticating: aad(providerID: providerID, connectionID: connectionID, keyID: keyID))
        guard let combined = box.combined else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider credential encryption failed", retryable: false)
        }
        return combined
    }

    private static func aad(providerID: ProviderSettingsID, connectionID: UUID, keyID: String) -> Data {
        Data("repoprompt-provider-vault-v2:\(providerID.rawValue):\(connectionID.uuidString):\(keyID)".utf8)
    }

    private static func validate(_ value: Document, keys: [String: SymmetricKey]) throws {
        guard value.schemaVersion == 2, value.generation >= 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault document metadata is invalid", retryable: false)
        }
        for (identifier, entry) in value.entries {
            guard identifier == entry.connectionID.uuidString,
                  entry.revision > 0,
                  ProviderSettingsID(rawValue: entry.providerID) != nil,
                  keys[entry.keyID] != nil,
                  Data(base64Encoded: entry.sealed) != nil
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault entry metadata is invalid", retryable: false)
            }
            guard let providerID = ProviderSettingsID(rawValue: entry.providerID),
                  let key = keys[entry.keyID],
                  let combined = Data(base64Encoded: entry.sealed)
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault entry key is unavailable", retryable: false)
            }
            do {
                _ = try AES.GCM.open(
                    AES.GCM.SealedBox(combined: combined),
                    using: key,
                    authenticating: aad(providerID: providerID, connectionID: entry.connectionID, keyID: entry.keyID)
                )
            } catch {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault entry authentication failed", retryable: false)
            }
        }
    }

    private static func prepareParent(of fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault parent must be a directory", retryable: false)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault parent must not be a symbolic link", retryable: false)
            }
            if let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value {
                guard owner == geteuid() else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault parent must be owned by the service account", retryable: false)
                }
            }
        } else {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let final = try FileManager.default.attributesOfItem(atPath: parent.path)
        guard (final[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault parent must have mode 0700", retryable: false)
        }
    }

    private static func requirePrivateFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault file must be a regular file with mode 0600", retryable: false)
        }
        if let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value {
            guard owner == geteuid() else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault file must be owned by the service account", retryable: false)
            }
        }
    }

    private struct PostReplacementWriteError: Error {
        let underlying: any Error
    }

    private static func write(_ document: Document, to destination: URL) throws {
        let data = try JSONEncoder.serviceEncoder.encode(document)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".provider-vault-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault temporary file could not be created", retryable: true)
        }
        var replacementCompleted = false
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, destination.path) == 0 else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault atomic replacement failed", retryable: true)
            }
            replacementCompleted = true
            try requirePrivateFile(destination)
            try synchronizeDirectory(destination.deletingLastPathComponent())
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if replacementCompleted {
                throw PostReplacementWriteError(underlying: error)
            }
            throw error
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault directory could not be opened for synchronization", retryable: true)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider vault directory synchronization failed", retryable: true)
        }
    }
}
