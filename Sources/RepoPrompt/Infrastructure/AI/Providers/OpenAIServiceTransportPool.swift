import CryptoKit
import Foundation
import SwiftOpenAI

struct OpenAIServiceSessionPolicy: Hashable {
    static let longRunning = OpenAIServiceSessionPolicy(
        requestTimeout: 21600,
        resourceTimeout: 21600,
        waitsForConnectivity: false
    )

    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let waitsForConnectivity: Bool

    func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = waitsForConnectivity
        return configuration
    }
}

final class OpenAIServiceTransportPool: @unchecked Sendable {
    static let shared = OpenAIServiceTransportPool()

    private struct CredentialIdentity: Hashable {
        let digest: Data

        init(_ credential: String) {
            digest = Data(SHA256.hash(data: Data(credential.utf8)))
        }
    }

    private struct Header: Hashable {
        let name: String
        let value: String
    }

    private enum Backend: Hashable {
        case openAI
        case azure
    }

    private struct Configuration: Hashable {
        let backend: Backend
        let baseURL: String
        let proxyPath: String?
        let apiVersion: String
        let credential: CredentialIdentity
        let extraHeaders: [Header]
        let includeUsageInStream: Bool
        let debugEnabled: Bool
        let sessionPolicy: OpenAIServiceSessionPolicy
    }

    private struct Entry {
        let service: OpenAIService
        var owners: Set<AIProviderType>
    }

    private let lock = NSLock()
    private var configurationByOwner: [AIProviderType: Configuration] = [:]
    private var entries: [Configuration: Entry] = [:]

    func openAIService(
        owner: AIProviderType,
        apiKey: String,
        baseURL: URL?,
        proxyPath: String? = nil,
        apiVersion: String?,
        extraHeaders: [String: String]? = nil,
        includeUsageInStream: Bool,
        debugEnabled: Bool = false,
        sessionPolicy: OpenAIServiceSessionPolicy = .longRunning
    ) -> OpenAIService {
        let effectiveBaseURL = baseURL?.absoluteString ?? "https://api.openai.com"
        let effectiveProxyPath = baseURL == nil ? nil : proxyPath
        let effectiveAPIVersion = baseURL == nil ? "v1" : (apiVersion ?? "v1")
        let effectiveExtraHeaders = baseURL == nil ? nil : extraHeaders
        let effectiveIncludeUsageInStream = baseURL == nil ? true : includeUsageInStream
        let effectiveDebugEnabled = baseURL == nil ? false : debugEnabled
        let transportConfiguration = Configuration(
            backend: .openAI,
            baseURL: effectiveBaseURL,
            proxyPath: effectiveProxyPath,
            apiVersion: effectiveAPIVersion,
            credential: CredentialIdentity(apiKey),
            extraHeaders: Self.canonicalHeaders(effectiveExtraHeaders),
            includeUsageInStream: effectiveIncludeUsageInStream,
            debugEnabled: effectiveDebugEnabled,
            sessionPolicy: sessionPolicy
        )

        return service(owner: owner, configuration: transportConfiguration) {
            let configuration = sessionPolicy.makeConfiguration()
            if let baseURL {
                return OpenAIServiceFactory.service(
                    apiKey: apiKey,
                    overrideBaseURL: baseURL.absoluteString,
                    configuration: configuration,
                    proxyPath: proxyPath,
                    overrideVersion: apiVersion,
                    extraHeaders: extraHeaders,
                    includeUsageInStream: includeUsageInStream,
                    debugEnabled: debugEnabled
                )
            }
            return OpenAIServiceFactory.service(
                apiKey: apiKey,
                configuration: configuration
            )
        }
    }

    func azureService(
        owner: AIProviderType = .azure,
        configuration: AzureOpenAIConfiguration,
        debugEnabled: Bool,
        sessionPolicy: OpenAIServiceSessionPolicy = .longRunning
    ) -> OpenAIService {
        let transportConfiguration = Configuration(
            backend: .azure,
            baseURL: configuration.baseURL.absoluteString,
            proxyPath: nil,
            apiVersion: configuration.apiVersion,
            credential: CredentialIdentity(configuration.apiKey),
            extraHeaders: Self.canonicalHeaders(configuration.extraHeaders),
            includeUsageInStream: true,
            debugEnabled: debugEnabled,
            sessionPolicy: sessionPolicy
        )

        return service(owner: owner, configuration: transportConfiguration) {
            OpenAIServiceFactory.service(
                azureConfiguration: configuration.toSwiftOpenAIConfiguration,
                urlSessionConfiguration: sessionPolicy.makeConfiguration(),
                debugEnabled: debugEnabled
            )
        }
    }

    var retainedServiceCountForTesting: Int {
        lock.withLock { entries.count }
    }

    private func service(
        owner: AIProviderType,
        configuration: Configuration,
        create: () -> OpenAIService
    ) -> OpenAIService {
        lock.withLock {
            if configurationByOwner[owner] != configuration {
                retireCurrentConfiguration(for: owner)
                configurationByOwner[owner] = configuration
            }

            if var entry = entries[configuration] {
                entry.owners.insert(owner)
                entries[configuration] = entry
                return entry.service
            }

            let newService = create()
            entries[configuration] = Entry(service: newService, owners: [owner])
            return newService
        }
    }

    private func retireCurrentConfiguration(for owner: AIProviderType) {
        guard let previousConfiguration = configurationByOwner.removeValue(forKey: owner),
              var previousEntry = entries[previousConfiguration]
        else {
            return
        }

        previousEntry.owners.remove(owner)
        if previousEntry.owners.isEmpty {
            // Dropping the cache reference leaves any active request or stream holding
            // the old service alive; no shared URLSession is invalidated or cancelled.
            entries.removeValue(forKey: previousConfiguration)
        } else {
            entries[previousConfiguration] = previousEntry
        }
    }

    private static func canonicalHeaders(_ headers: [String: String]?) -> [Header] {
        (headers ?? [:])
            .map { Header(name: $0.key, value: $0.value) }
            .sorted {
                if $0.name == $1.name {
                    return $0.value < $1.value
                }
                return $0.name < $1.name
            }
    }
}
