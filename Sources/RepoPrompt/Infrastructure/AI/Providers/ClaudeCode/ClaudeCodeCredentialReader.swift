import Foundation
import RepoPromptProviderQuota
import Security

/// A selected CLI config profile, never an inferred account identity. Constructing this value
/// does no filesystem canonicalization or credential IO. Identity is the selected config
/// folder, not its current token/account. Custom profiles never fall back to the unscoped global Keychain item.
struct ClaudeUsageCredentialProfile: Equatable {
    let directory: URL
    let isDefault: Bool
    var id: String {
        directory.path
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let defaultDirectory = home.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
        let override = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL = if let override, !override.isEmpty {
            URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        } else { defaultDirectory }
        return Self(directory: directory, isDefault: directory == defaultDirectory)
    }
}

struct ClaudeUsageCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: String
    let profileID: String
    var description: String {
        "ClaudeUsageCredential(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }
}

/// Read-only CLI credential access. No security subprocess, browser cookies, token refresh,
/// credential writes, or interactive Keychain access during automatic acquisition.
protocol ClaudeUsageCredentialReading: Sendable {
    func read(profile: ClaudeUsageCredentialProfile, userInitiated: Bool) async throws -> ClaudeUsageCredential
}

actor ClaudeCodeCredentialReader: ClaudeUsageCredentialReading {
    private let readFile: @Sendable (URL) throws -> Data?
    private let readKeychain: @Sendable (Bool) throws -> Data
    private let now: @Sendable () -> Date

    init(
        readFile: @escaping @Sendable (URL) throws -> Data? = { try ClaudeCodeCredentialReader.readCredentialFile($0) },
        readKeychain: @escaping @Sendable (Bool) throws -> Data = { try ClaudeCodeCredentialReader.readCredentialKeychain($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readFile = readFile
        self.readKeychain = readKeychain
        self.now = now
    }

    private enum SelectionError: Error { case expired }

    func read(profile: ClaudeUsageCredentialProfile, userInitiated: Bool) throws -> ClaudeUsageCredential {
        let file = profile.directory.appendingPathComponent(".credentials.json")
        do {
            if let data = try readFile(file) {
                guard data.count <= 65536 else { throw ProviderQuotaReadError.signInRequired }
                do {
                    // A usable profile file wins. Only an expired default-profile record
                    // may recover from Claude Code's own Keychain item; custom profiles,
                    // malformed files, and insufficient scopes never select another source.
                    return try Self.decodeForSelection(data, profileID: profile.id, now: now())
                } catch SelectionError.expired where profile.isDefault {
                    // Claude Code can rotate its Keychain token without updating this file.
                }
            }
            guard profile.isDefault else { throw ProviderQuotaReadError.signInRequired }
            let data = try readKeychain(userInitiated)
            guard data.count <= 65536 else { throw ProviderQuotaReadError.signInRequired }
            return try Self.decode(data, profileID: profile.id, now: now())
        } catch let error as ProviderQuotaReadError { throw error }
        catch { throw ProviderQuotaReadError.signInRequired }
    }

    private nonisolated static func readCredentialFile(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: 65537) ?? Data()
    }

    private nonisolated static func readCredentialKeychain(_ userInitiated: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: userInitiated ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65536 else {
            throw ProviderQuotaReadError.signInRequired
        }
        return data
    }

    static func decode(_ data: Data, profileID: String, now: Date = Date()) throws -> ClaudeUsageCredential {
        do { return try decodeForSelection(data, profileID: profileID, now: now) }
        catch SelectionError.expired { throw ProviderQuotaReadError.signInRequired }
    }

    private static func decodeForSelection(_ data: Data, profileID: String, now: Date) throws -> ClaudeUsageCredential {
        struct Record: Decodable {
            struct OAuth: Decodable { let accessToken: String
                let expiresAt: Double?
                let scopes: [String]?
            }

            let claudeAiOauth: OAuth?
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), let oauth = record.claudeAiOauth,
              !oauth.accessToken.isEmpty, oauth.accessToken.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F })
        else {
            throw ProviderQuotaReadError.signInRequired
        }
        if let expiration = oauth.expiresAt {
            guard expiration.isFinite else { throw ProviderQuotaReadError.signInRequired }
            if expiration / 1000 <= now.timeIntervalSince1970 { throw SelectionError.expired }
        }
        if let scopes = oauth.scopes, !scopes.contains("user:profile") { throw ProviderQuotaReadError.insufficientScope }
        return ClaudeUsageCredential(token: oauth.accessToken, profileID: profileID)
    }
}
