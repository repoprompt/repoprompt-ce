import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
@preconcurrency import NIOSSL
import RepoPromptServiceProtocol

public enum ValidatedProviderEgressError: Error, Equatable, Sendable {
    case invalidEndpoint
    case unsupportedPort
    case nameResolutionFailed
    case nonPublicAddress
    case transportUnavailable
    case tlsValidationFailed
    case redirectRejected
    case responseHeadersTooLarge
    case responseBodyTooLarge
    case invalidResponse
    case timedOut
    case cancelled
}

public struct ValidatedProviderHTTPRequest: Sendable {
    public let endpoint: DirectProviderEndpoint
    public let method: String
    public let pathAndQuery: String
    public let headers: [String: String]
    public let body: Data?
    public let maximumResponseHeaderBytes: Int
    public let maximumResponseBodyBytes: Int
    public let connectTimeout: Duration
    public let totalTimeout: Duration

    public init(
        endpoint: DirectProviderEndpoint,
        method: String,
        pathAndQuery: String,
        headers: [String: String],
        body: Data? = nil,
        maximumResponseHeaderBytes: Int = 64 * 1024,
        maximumResponseBodyBytes: Int = 2 * 1024 * 1024,
        connectTimeout: Duration = .seconds(5),
        totalTimeout: Duration = .seconds(30)
    ) {
        self.endpoint = endpoint
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.headers = headers
        self.body = body
        self.maximumResponseHeaderBytes = maximumResponseHeaderBytes
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
        self.connectTimeout = connectTimeout
        self.totalTimeout = totalTimeout
    }
}

public struct ValidatedProviderHTTPResponse: Sendable {
    public let statusCode: Int
    public let contentType: String?
    public let body: Data

    public init(statusCode: Int, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public protocol ValidatedProviderEgressTransporting: Sendable {
    func validateEndpoint(_ baseURL: String) async throws -> DirectProviderEndpoint
    func execute(_ request: ValidatedProviderHTTPRequest) async throws -> ValidatedProviderHTTPResponse
}

struct ResolvedProviderAddress: Sendable, Hashable {
    let ipAddress: String
    let socketAddress: SocketAddress
}

protocol ProviderHostResolving: Sendable {
    func resolve(host: String, port: Int) async throws -> [ResolvedProviderAddress]
}

struct SystemProviderHostResolver: ProviderHostResolving {
    func resolve(host: String, port: Int) async throws -> [ResolvedProviderAddress] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_flags = AI_ADDRCONFIG
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM_VALUE
            hints.ai_protocol = Int32(IPPROTO_TCP)
            var result: UnsafeMutablePointer<addrinfo>?
            let status = host.withCString { hostPointer in
                String(port).withCString { servicePointer in
                    getaddrinfo(hostPointer, servicePointer, &hints, &result)
                }
            }
            guard status == 0, let first = result else {
                throw ValidatedProviderEgressError.nameResolutionFailed
            }
            defer { freeaddrinfo(first) }

            var addresses: [ResolvedProviderAddress] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor?.pointee {
                defer { cursor = entry.ai_next }
                guard entry.ai_family == AF_INET || entry.ai_family == AF_INET6,
                      let rawAddress = entry.ai_addr
                else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    rawAddress,
                    socklen_t(entry.ai_addrlen),
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard nameStatus == 0 else { continue }
                let ipAddress = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let socketAddress = try SocketAddress(ipAddress: ipAddress, port: port)
                addresses.append(.init(ipAddress: ipAddress, socketAddress: socketAddress))
            }
            let unique = Array(Set(addresses)).sorted { $0.ipAddress < $1.ipAddress }
            guard !unique.isEmpty else { throw ValidatedProviderEgressError.nameResolutionFailed }
            return unique
        }.value
    }

    private var SOCK_STREAM_VALUE: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }
}

/// Desktop accepts local provider URLs (Ollama default `http://localhost:11434`,
/// custom / OpenAI base URLs). Linux keeps the public-HTTPS SSRF gate and
/// unlocks loopback only when the operator sets this escape.
public enum ProviderLocalURLEscape {
    public static let environmentKey = "REPOPROMPT_ALLOW_LOCAL_PROVIDER_URLS"

    public static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ["1", "true", "yes"].contains((environment[environmentKey] ?? "").lowercased())
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" { return true }
        return ProviderEgressAddressPolicy.isLoopbackAddress(normalized)
    }
}

public enum ProviderEgressAddressPolicy {
    public static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }

    public static func isPublicAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4.s_addr) { Array($0) }
            return isPublicIPv4(bytes)
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return isPublicIPv6(bytes)
        }
        return false
    }

    public static func isLoopbackAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4.s_addr) { Array($0) }
            return bytes.count == 4 && bytes[0] == 127
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            guard bytes.count == 16 else { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            if bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0,
               bytes[4] == 0, bytes[5] == 0, bytes[6] == 0, bytes[7] == 0,
               bytes[8] == 0, bytes[9] == 0, bytes[10] == 0xFF, bytes[11] == 0xFF,
               bytes[12] == 127
            {
                return true
            }
        }
        return false
    }

    static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1], c = bytes[2], d = bytes[3]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100, (64 ... 127).contains(b) { return false }
        if a == 169, b == 254 { return false }
        if a == 172, (16 ... 31).contains(b) { return false }
        if a == 192, b == 0, c == 0 { return false }
        if a == 192, b == 0, c == 2 { return false }
        if a == 192, b == 88, c == 99 { return false }
        if a == 192, b == 168 { return false }
        if a == 198, b == 18 || b == 19 { return false }
        if a == 198, b == 51, c == 100 { return false }
        if a == 203, b == 0, c == 113 { return false }
        // Azure platform metadata/DNS endpoint is not link-local.
        if a == 168, b == 63, c == 129, d == 16 { return false }
        return true
    }

    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // Only global unicast is eligible. This rejects unspecified, loopback,
        // IPv4-compatible/mapped, translation, link-local, ULA and multicast.
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        // Documentation and benchmarking/special-use ranges inside 2000::/3.
        if bytes[0] == 0x20, bytes[1] == 0x01 {
            if bytes[2] == 0x0D, bytes[3] == 0xB8 { return false } // 2001:db8::/32
            if bytes[2] < 0x02 { return false } // 2001:0000::/23 special-use
            if bytes[2] == 0x00, bytes[3] & 0xF0 == 0x20 { return false }
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false } // 6to4 indirection
        if bytes[0] == 0x3F, bytes[1] & 0xF0 == 0xF0 { return false } // 3fff::/20 docs
        return true
    }
}

public struct ProviderEndpointPolicy {
    public static func parseCustomBaseURL(_ value: String, allowLocalURLs: Bool = false) throws -> DirectProviderEndpoint {
        guard value.utf8.count <= 2048,
              let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              host.utf8.count <= 253
        else { throw ValidatedProviderEgressError.invalidEndpoint }

        let local = allowLocalURLs && ProviderLocalURLEscape.isLoopbackHost(host)
        if local {
            guard ["http", "https"].contains(scheme) else { throw ValidatedProviderEgressError.invalidEndpoint }
        } else {
            guard scheme == "https",
                  components.port == nil || components.port == 443,
                  host.range(of: "^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil,
                  !ProviderEgressAddressPolicy.isIPAddress(host)
            else { throw ValidatedProviderEgressError.invalidEndpoint }
        }
        let port = local ? (components.port ?? (scheme == "https" ? 443 : 80)) : 443
        guard (1 ... 65_535).contains(port) else { throw ValidatedProviderEgressError.invalidEndpoint }

        let path = components.percentEncodedPath.isEmpty ? "" : components.percentEncodedPath
        let lowercasePath = path.lowercased()
        guard path.utf8.count <= 1024,
              !lowercasePath.contains("%2e"),
              !lowercasePath.contains("%2f"),
              !lowercasePath.contains("%5c"),
              !lowercasePath.contains("%00"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw ValidatedProviderEgressError.invalidEndpoint }
        let normalizedPath = path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return DirectProviderEndpoint(
            scheme: scheme,
            host: host,
            port: port,
            basePath: normalizedPath.isEmpty ? "" : "/\(normalizedPath)"
        )
    }

    public static func fixed(providerID: ProviderSettingsID) throws -> DirectProviderEndpoint {
        switch providerID {
        case .openAIAPI:
            .init(scheme: "https", host: "api.openai.com", port: 443, basePath: "/v1")
        case .anthropicAPI:
            .init(scheme: "https", host: "api.anthropic.com", port: 443, basePath: "/v1")
        case .openRouter:
            .init(scheme: "https", host: "openrouter.ai", port: 443, basePath: "/api/v1")
        case .gemini:
            .init(scheme: "https", host: "generativelanguage.googleapis.com", port: 443, basePath: "/v1beta")
        case .deepseek:
            .init(scheme: "https", host: "api.deepseek.com", port: 443, basePath: "/v1")
        case .fireworks:
            .init(scheme: "https", host: "api.fireworks.ai", port: 443, basePath: "/inference/v1")
        case .xAI:
            .init(scheme: "https", host: "api.x.ai", port: 443, basePath: "/v1")
        case .groq:
            .init(scheme: "https", host: "api.groq.com", port: 443, basePath: "/openai/v1")
        case .zAI:
            .init(scheme: "https", host: "api.z.ai", port: 443, basePath: "/api/paas/v4")
        default:
            throw ValidatedProviderEgressError.invalidEndpoint
        }
    }

    /// Desktop Ollama persists any local or remote URL (default
    /// `http://localhost:11434`). Persist accepts that contract. Execute still
    /// uses the public-HTTPS SSRF gate unless `REPOPROMPT_ALLOW_LOCAL_PROVIDER_URLS`
    /// unlocks loopback.
    public static func parseOllamaBaseURL(_ value: String) throws -> DirectProviderEndpoint {
        guard value.utf8.count <= 2048,
              let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              host.utf8.count <= 253
        else { throw ValidatedProviderEgressError.invalidEndpoint }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1 ... 65_535).contains(port) else { throw ValidatedProviderEgressError.invalidEndpoint }
        let path = components.percentEncodedPath.isEmpty ? "" : components.percentEncodedPath
        let lowercasePath = path.lowercased()
        guard path.utf8.count <= 1024,
              !lowercasePath.contains("%2e"),
              !lowercasePath.contains("%2f"),
              !lowercasePath.contains("%5c"),
              !lowercasePath.contains("%00"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw ValidatedProviderEgressError.invalidEndpoint }
        let normalizedPath = path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return DirectProviderEndpoint(
            scheme: scheme,
            host: host,
            port: port,
            basePath: normalizedPath.isEmpty ? "" : "/\(normalizedPath)"
        )
    }
}

public final class ValidatedProviderEgressTransport: ValidatedProviderEgressTransporting, @unchecked Sendable {
    private let resolver: any ProviderHostResolving
    private let eventLoopGroup: EventLoopGroup
    private let tlsContext: NIOSSLContext
    private let allowLocalURLs: Bool

    public convenience init(allowLocalURLs: Bool = ProviderLocalURLEscape.isEnabled()) throws {
        try self.init(resolver: SystemProviderHostResolver(), allowLocalURLs: allowLocalURLs)
    }

    init(
        resolver: any ProviderHostResolving,
        eventLoopGroup: EventLoopGroup = NIOSingletons.posixEventLoopGroup,
        allowLocalURLs: Bool = ProviderLocalURLEscape.isEnabled()
    ) throws {
        self.resolver = resolver
        self.eventLoopGroup = eventLoopGroup
        self.allowLocalURLs = allowLocalURLs
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        configuration.minimumTLSVersion = .tlsv12
        configuration.maximumTLSVersion = .tlsv13
        tlsContext = try NIOSSLContext(configuration: configuration)
    }

    public func validateEndpoint(_ baseURL: String) async throws -> DirectProviderEndpoint {
        let endpoint = try ProviderEndpointPolicy.parseCustomBaseURL(baseURL, allowLocalURLs: allowLocalURLs)
        _ = try await validatedAddresses(for: endpoint)
        return endpoint
    }

    public func execute(_ request: ValidatedProviderHTTPRequest) async throws -> ValidatedProviderHTTPResponse {
        try validateRequest(request)
        let addresses = try await validatedAddresses(for: request.endpoint)
        var lastError: Error = ValidatedProviderEgressError.transportUnavailable
        for address in addresses {
            do {
                return try await execute(request, address: address.socketAddress)
            } catch is CancellationError {
                throw ValidatedProviderEgressError.cancelled
            } catch let error as ValidatedProviderEgressError where error == .redirectRejected
                || error == .responseHeadersTooLarge
                || error == .responseBodyTooLarge
                || error == .invalidResponse
                || error == .tlsValidationFailed
            {
                throw error
            } catch {
                lastError = error
            }
        }
        if let error = lastError as? ValidatedProviderEgressError { throw error }
        throw ValidatedProviderEgressError.transportUnavailable
    }

    private func validatedAddresses(for endpoint: DirectProviderEndpoint) async throws -> [ResolvedProviderAddress] {
        let local = allowLocalURLs && ProviderLocalURLEscape.isLoopbackHost(endpoint.host)
        if local {
            guard ["http", "https"].contains(endpoint.scheme), (1 ... 65_535).contains(endpoint.port) else {
                throw ValidatedProviderEgressError.unsupportedPort
            }
        } else if endpoint.scheme != "https" || endpoint.port != 443 {
            throw ValidatedProviderEgressError.unsupportedPort
        }
        let addresses = try await resolver.resolve(host: endpoint.host, port: endpoint.port)
        // Reject a mixed public/private answer rather than choosing the public
        // member; every retry and every request receives a fresh all-record check.
        if local {
            guard addresses.allSatisfy({ ProviderEgressAddressPolicy.isLoopbackAddress($0.ipAddress) }) else {
                throw ValidatedProviderEgressError.nonPublicAddress
            }
        } else if !addresses.allSatisfy({ ProviderEgressAddressPolicy.isPublicAddress($0.ipAddress) }) {
            throw ValidatedProviderEgressError.nonPublicAddress
        }
        return addresses
    }

    func validateRequest(_ request: ValidatedProviderHTTPRequest) throws {
        let local = allowLocalURLs && ProviderLocalURLEscape.isLoopbackHost(request.endpoint.host)
        let schemeOK = local
            ? ["http", "https"].contains(request.endpoint.scheme)
            : request.endpoint.scheme == "https"
        let portOK = local
            ? (1 ... 65_535).contains(request.endpoint.port)
            : request.endpoint.port == 443
        guard schemeOK,
              portOK,
              ["GET", "POST"].contains(request.method),
              request.pathAndQuery.hasPrefix("/"),
              request.pathAndQuery.utf8.count <= 4096,
              !request.pathAndQuery.contains("#"),
              request.maximumResponseHeaderBytes > 0,
              request.maximumResponseHeaderBytes <= 256 * 1024,
              request.maximumResponseBodyBytes > 0,
              request.maximumResponseBodyBytes <= 8 * 1024 * 1024,
              request.body?.count ?? 0 <= 2 * 1024 * 1024,
              request.connectTimeout > .zero,
              request.totalTimeout > .zero,
              request.connectTimeout <= request.totalTimeout
        else { throw ValidatedProviderEgressError.invalidEndpoint }
        let requestHeaderBytes = request.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }
        guard request.headers.count <= 64, requestHeaderBytes <= 64 * 1024 else {
            throw ValidatedProviderEgressError.responseHeadersTooLarge
        }
    }

    private func execute(_ request: ValidatedProviderHTTPRequest, address: SocketAddress) async throws -> ValidatedProviderHTTPResponse {
        let useTLS = request.endpoint.scheme == "https"
        let connectionPlan = useTLS ? try ProviderPinnedTLSConnectionPlan(endpoint: request.endpoint, address: address) : nil
        if !useTLS {
            guard allowLocalURLs, ProviderLocalURLEscape.isLoopbackHost(request.endpoint.host) else {
                throw ValidatedProviderEgressError.unsupportedPort
            }
        }
        let responsePromise = eventLoopGroup.next().makePromise(of: ValidatedProviderHTTPResponse.self)
        let tlsContext = tlsContext
        let handler = BoundedProviderHTTPResponseHandler(
            promise: responsePromise,
            maximumHeaderBytes: request.maximumResponseHeaderBytes,
            maximumBodyBytes: request.maximumResponseBodyBytes
        )
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.nanoseconds(request.connectTimeout.nanosecondsClamped))
            .channelInitializer { channel in
                do {
                    if useTLS, let connectionPlan {
                        let tls = try NIOSSLClientHandler(context: tlsContext, serverHostname: connectionPlan.serverHostname)
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(to: connectionPlan?.address ?? address).get()
        } catch {
            throw useTLS ? ValidatedProviderEgressError.tlsValidationFailed : ValidatedProviderEgressError.transportUnavailable
        }
        defer { channel.close(promise: nil) }

        var headers = HTTPHeaders()
        let defaultPort = request.endpoint.scheme == "https" ? 443 : 80
        let hostHeader = request.endpoint.port == defaultPort
            ? request.endpoint.host
            : "\(request.endpoint.host):\(request.endpoint.port)"
        headers.add(name: "Host", value: hostHeader)
        headers.add(name: "Accept", value: "application/json, text/event-stream")
        headers.add(name: "Connection", value: "close")
        for (name, value) in request.headers { headers.replaceOrAdd(name: name, value: value) }
        if let body = request.body { headers.replaceOrAdd(name: "Content-Length", value: String(body.count)) }
        let head = HTTPRequestHead(
            version: .http1_1,
            method: HTTPMethod(rawValue: request.method),
            uri: request.pathAndQuery,
            headers: headers
        )
        try await channel.write(HTTPClientRequestPart.head(head)).get()
        if let body = request.body {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            try await channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer))).get()
        }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()

        let timeoutTask = channel.eventLoop.scheduleTask(in: .nanoseconds(request.totalTimeout.nanosecondsClamped)) {
            handler.abort(.timedOut, channel: channel)
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await responsePromise.futureResult.get()
        } onCancel: {
            channel.eventLoop.execute {
                handler.abort(.cancelled, channel: channel)
            }
        }
    }
}

struct ProviderPinnedTLSConnectionPlan {
    let address: SocketAddress
    let serverHostname: String

    init(endpoint: DirectProviderEndpoint, address: SocketAddress) throws {
        guard endpoint.scheme == "https",
              (1 ... 65_535).contains(endpoint.port),
              !endpoint.host.isEmpty, !ProviderEgressAddressPolicy.isIPAddress(endpoint.host)
        else { throw ValidatedProviderEgressError.invalidEndpoint }
        self.address = address
        serverHostname = endpoint.host
    }
}

struct BoundedProviderResponseAccumulator {
    private let maximumHeaderBytes: Int
    private let maximumBodyBytes: Int
    private var statusCode: Int?
    private var contentType: String?
    private var body = Data()

    init(maximumHeaderBytes: Int, maximumBodyBytes: Int) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }

    mutating func receiveHead(statusCode: Int, headers: [(String, String)]) throws {
        let headerBytes = headers.reduce(0) { $0 + $1.0.utf8.count + $1.1.utf8.count + 4 }
        guard headerBytes <= maximumHeaderBytes else {
            throw ValidatedProviderEgressError.responseHeadersTooLarge
        }
        guard !(300 ..< 400).contains(statusCode) else {
            throw ValidatedProviderEgressError.redirectRejected
        }
        self.statusCode = statusCode
        contentType = headers.first { $0.0.caseInsensitiveCompare("content-type") == .orderedSame }
            .map { String($0.1.prefix(256)) }
    }

    mutating func receiveBody(_ bytes: [UInt8]) throws {
        guard body.count + bytes.count <= maximumBodyBytes else {
            throw ValidatedProviderEgressError.responseBodyTooLarge
        }
        body.append(contentsOf: bytes)
    }

    func finish() throws -> ValidatedProviderHTTPResponse {
        guard let statusCode else { throw ValidatedProviderEgressError.invalidResponse }
        return .init(statusCode: statusCode, contentType: contentType, body: body)
    }
}

private final class BoundedProviderHTTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<ValidatedProviderHTTPResponse>
    private var accumulator: BoundedProviderResponseAccumulator
    private var completed = false

    init(promise: EventLoopPromise<ValidatedProviderHTTPResponse>, maximumHeaderBytes: Int, maximumBodyBytes: Int) {
        self.promise = promise
        accumulator = .init(maximumHeaderBytes: maximumHeaderBytes, maximumBodyBytes: maximumBodyBytes)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        do {
            switch unwrapInboundIn(data) {
            case let .head(head):
                try accumulator.receiveHead(
                    statusCode: Int(head.status.code),
                    headers: head.headers.map { ($0.name, $0.value) }
                )
            case var .body(buffer):
                try accumulator.receiveBody(buffer.readBytes(length: buffer.readableBytes) ?? [])
            case .end:
                let response = try accumulator.finish()
                completed = true
                promise.succeed(response)
            }
        } catch let error as ValidatedProviderEgressError {
            fail(error, context: context)
        } catch {
            fail(.invalidResponse, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        fail(.transportUnavailable, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed { fail(.invalidResponse, context: context) }
    }

    func abort(_ error: ValidatedProviderEgressError, channel: Channel) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
        channel.close(promise: nil)
    }

    private func fail(_ error: ValidatedProviderEgressError, context: ChannelHandlerContext) {
        abort(error, channel: context.channel)
    }
}

private extension Duration {
    var nanosecondsClamped: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if seconds.overflow { return Int64.max }
        let attoseconds = components.attoseconds / 1_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(attoseconds)
        return total.overflow ? Int64.max : max(1, total.partialValue)
    }
}
