import Foundation
import RepoPromptProviderQuota

struct ClaudeUsageHTTPResponse {
    let statusCode: Int
    let data: Data
    let retryAfter: String?
}

protocol ClaudeUsageHTTPTransport: Sendable {
    func response(path: String, credential: ClaudeUsageCredential) async throws -> ClaudeUsageHTTPResponse
}

/// Deliberately rejects every redirect, including same-host redirects. Bearer credentials must
/// never follow an endpoint change. Session/cache/cookies exist only for the admitted request.
struct ClaudeUsageURLSessionTransport: ClaudeUsageHTTPTransport {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func response(path: String, credential: ClaudeUsageCredential) async throws -> ClaudeUsageHTTPResponse {
        guard path == "/api/oauth/usage" || path == "/api/oauth/profile",
              let url = URL(string: "https://api.anthropic.com" + path), url.host == "api.anthropic.com"
        else {
            throw ProviderQuotaReadError.invalidResponse
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url?.host == url.host,
              data.count <= 1_048_576 else { throw ProviderQuotaReadError.invalidResponse }
        return ClaudeUsageHTTPResponse(
            statusCode: response.statusCode,
            data: data,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After")
        )
    }
}

/// Read-only acquisition using one explicitly granted config profile. Profile identity is
/// checked before and after every suspension; the coordinator supplies an additional lifetime
/// generation fence. SDK events and API keys are not account-usage credentials.
actor ClaudeAccountUsageSource {
    private let reader: any ClaudeUsageCredentialReading
    private let transport: any ClaudeUsageHTTPTransport
    private let profileProvider: @Sendable () -> ClaudeUsageCredentialProfile
    private let consentProvider: @Sendable () async -> String?
    private var interactiveUntil: Date?
    private let now: @Sendable () -> Date

    init(
        reader: any ClaudeUsageCredentialReading = ClaudeCodeCredentialReader(),
        transport: any ClaudeUsageHTTPTransport = ClaudeUsageURLSessionTransport(),
        profileProvider: @escaping @Sendable () -> ClaudeUsageCredentialProfile = { .current() },
        now: @escaping @Sendable () -> Date = { Date() },
        consentProvider: @escaping @Sendable () async -> String?
    ) {
        self.now = now
        self.reader = reader
        self.transport = transport
        self.profileProvider = profileProvider
        self.consentProvider = consentProvider
    }

    func prepareUserConnection() {
        interactiveUntil = now().addingTimeInterval(30)
    }

    func cancelUserConnection() {
        interactiveUntil = nil
    }

    func read(_ context: ProviderQuotaReadContext) async throws -> ProviderQuotaSnapshot {
        let interactive = context.userInitiated || interactiveUntil.map { $0 > now() } == true
        interactiveUntil = nil
        let profile = profileProvider()
        guard await consentProvider() == profile.id else { throw ProviderQuotaReadError.needsConsent }
        try await validate(profile)
        var credential = try await reader.read(profile: profile, userInitiated: interactive)
        guard credential.profileID == profile.id else { throw ProviderQuotaReadError.needsConsent }
        try await validate(profile)
        // Bounded, read-only retry can adopt a token rotated by Claude Code. We never rotate
        // credentials ourselves or retry scope/rate-limit/network failures.
        for attempt in 0 ... 1 {
            do {
                let profileResponse = try await transport.response(path: "/api/oauth/profile", credential: credential)
                try Self.check(profileResponse, now: now())
                try await validate(profile)
                let account = try Self.account(data: profileResponse.data, profileID: profile.id)
                do {
                    let usage = try await transport.response(path: "/api/oauth/usage", credential: credential)
                    try Self.check(usage, now: now())
                    try await validate(profile)
                    return try ClaudeAccountUsageMapper.snapshot(data: usage.data, account: account, observedAt: now())
                } catch {
                    // A confirmed change/lost account binding must not leave the previous
                    // account's numbers in the cache when its replacement read fails.
                    if context.expectedAccount.map({ $0 != account }) == true, !(error is CancellationError) {
                        if let failure = error as? ProviderQuotaReadError {
                            switch failure {
                            case .signInRequired, .insufficientScope, .needsConsent: throw error
                            case let .rateLimited(until): throw ProviderQuotaReadError.accountInvalidated(retryAt: until)
                            default: break
                            }
                        }
                        throw ProviderQuotaReadError.accountInvalidated(retryAt: nil)
                    }
                    throw error
                }
            } catch ProviderQuotaReadError.signInRequired where attempt == 0 {
                let replacement = try await reader.read(profile: profile, userInitiated: false)
                guard replacement.profileID == profile.id else { throw ProviderQuotaReadError.needsConsent }
                guard replacement.token != credential.token else { throw ProviderQuotaReadError.signInRequired }
                credential = replacement
                try await validate(profile)
            }
        }
        throw ProviderQuotaReadError.signInRequired
    }

    private func validate(_ profile: ClaudeUsageCredentialProfile) async throws {
        try Task.checkCancellation()
        guard profileProvider() == profile, await consentProvider() == profile.id else {
            throw ProviderQuotaReadError.needsConsent
        }
    }

    static func check(_ response: ClaudeUsageHTTPResponse, now: Date = Date()) throws {
        switch response.statusCode {
        case 200: return
        case 401: throw ProviderQuotaReadError.signInRequired
        case 403: throw ProviderQuotaReadError.insufficientScope
        case 429: throw ProviderQuotaReadError.rateLimited(until: retryDate(response.retryAfter, now: now))
        case 300 ... 399: throw ProviderQuotaReadError.invalidResponse
        default: throw ProviderQuotaReadError.transport
        }
    }

    static func retryDate(_ raw: String?, now: Date) -> Date {
        if let raw, let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return raw.flatMap(formatter.date(from:)) ?? now.addingTimeInterval(900)
    }

    static func account(data: Data, profileID: String) throws -> ProviderAccountKey {
        struct Profile: Decodable {
            struct Identity: Decodable { let uuid: String? }
            let account: Identity?
            let organization: Identity?
        }
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else {
            throw ProviderQuotaReadError.invalidResponse
        }
        let identifier: String?
        if let account = profile.account?.uuid, !account.isEmpty {
            // Length-prefixed components avoid concatenation collisions, and preserve org scope.
            let organization = profile.organization?.uuid ?? ""
            identifier = "\(account.utf8.count):\(account)\(organization.utf8.count):\(organization)"
        } else { identifier = nil }
        return ProviderAccountKey(lineage: .anthropicFirstParty, opaqueAccountID: identifier, credentialProfileID: profileID)
    }
}
