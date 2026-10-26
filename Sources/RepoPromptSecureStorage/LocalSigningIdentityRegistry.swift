import Darwin
import Foundation

struct LocalSigningIdentityRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let certificateName: String
    let certificateSHA256: String
    let serviceGeneration: Int
}

enum LocalSigningIdentityRegistryError: Error, Equatable {
    case missing
    case notRegularFile
    case wrongOwner
    case insecurePermissions
    case unreadable
    case invalidRecord
}

enum LocalSigningIdentityRegistry {
    static let relativePath = "RepoPrompt CE/local-signing-identity-v1.json"

    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(relativePath)
    }

    static func load(
        from url: URL,
        fileManager: FileManager = .default,
        expectedOwnerID: UInt32 = getuid()
    ) -> Result<LocalSigningIdentityRecord, LocalSigningIdentityRegistryError> {
        _ = fileManager
        var fileStatus = Darwin.stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            return .failure(errno == ENOENT ? .missing : .unreadable)
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            return .failure(.notRegularFile)
        }
        guard fileStatus.st_uid == expectedOwnerID else {
            return .failure(.wrongOwner)
        }
        guard fileStatus.st_mode & 0o077 == 0 else {
            return .failure(.insecurePermissions)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return .failure(.unreadable)
        }
        guard let record = try? JSONDecoder().decode(LocalSigningIdentityRecord.self, from: data),
              record.schemaVersion == LocalSigningIdentityRecord.currentSchemaVersion,
              record.certificateName == RuntimeCodeSigningPolicy.localSelfSignedCertificateName,
              normalizedFingerprint(record.certificateSHA256)?.count == 64,
              record.serviceGeneration > 0
        else {
            return .failure(.invalidRecord)
        }
        return .success(record)
    }

    static func normalizedFingerprint(_ value: String) -> String? {
        let normalized = value.filter(\.isHexDigit).uppercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }
}
