import Foundation
import Network
import RepoPromptRemoteProtocol
import Security

struct RemoteLegacyHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

enum RemoteLegacyHTTPParser {
    static let maximumBufferedRequestBytes = 1_048_576

    static func nextRequest(from buffer: inout Data) -> RemoteLegacyHTTPRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex ..< headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            buffer.removeAll()
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].lowercased()
            let value = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= maximumBufferedRequestBytes else {
            buffer.removeAll(keepingCapacity: true)
            return nil
        }
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let bodyEnd = bodyStart + contentLength
        let body = buffer.subdata(in: bodyStart ..< bodyEnd)
        buffer.removeSubrange(buffer.startIndex ..< bodyEnd)
        return RemoteLegacyHTTPRequest(
            method: requestParts[0],
            target: requestParts[1],
            headers: headers,
            body: body
        )
    }
}

enum RemoteLegacyHTTPRequestDecodingResult {
    case request(RemoteGatewayRequest)
    case response(RemoteGatewayResponse)
}

enum RemoteLegacyHTTPRequestDecoder {
    static func decode(_ request: RemoteLegacyHTTPRequest) -> RemoteLegacyHTTPRequestDecodingResult {
        guard let components = URLComponents(string: request.target) else {
            return .response(.error(
                .init(code: "invalid_request", message: "Invalid request target."),
                status: 400
            ))
        }

        switch (request.method, components.path) {
        case ("POST", RemoteProtocol.pairingPath):
            guard let pairingRequest = try? JSONDecoder().decode(RemotePairingRequest.self, from: request.body) else {
                return .response(.error(
                    .init(code: "invalid_pairing_request", message: "Invalid pairing request."),
                    status: 400
                ))
            }
            return .request(.pair(pairingRequest))

        case ("POST", RemoteProtocol.unpairPath):
            return .request(.unpair)

        case ("GET", RemoteProtocol.transportBootstrapPath):
            return .request(.transportBootstrap)

        case ("POST", RemoteProtocol.irohBindingPath):
            guard let bindingRequest = try? JSONDecoder().decode(RemoteIrohBindingRequest.self, from: request.body) else {
                return .response(.error(
                    .init(code: "invalid_endpoint_binding", message: "Invalid Iroh endpoint binding request."),
                    status: 400
                ))
            }
            return .request(.bindIrohEndpoint(bindingRequest))

        case ("GET", RemoteProtocol.snapshotPath):
            return .request(.snapshot)

        case ("GET", RemoteProtocol.diagnosticsPath):
            return .request(.diagnostics)

        case ("GET", RemoteProtocol.workspacesPath):
            return .request(.workspaces)

        case ("GET", RemoteProtocol.sessionsPath):
            return .request(.sessions)

        case ("GET", RemoteProtocol.agentsPath):
            return .request(.agents)

        case ("GET", RemoteProtocol.workflowsPath):
            return .request(.workflows)

        case ("GET", RemoteProtocol.historyPath):
            let query = components.queryItems?.first(where: { $0.name == "q" })?.value
            let limit = components.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50
            return .request(.history(query: query, limit: limit))

        case ("GET", RemoteProtocol.transcriptPath):
            return decodeTranscript(components)

        case ("GET", RemoteProtocol.eventsPath):
            let cursor = components.queryItems?.first(where: { $0.name == "after" }).flatMap(\.value).flatMap(UInt64.init)
            return .request(.events(after: cursor))

        case ("POST", RemoteProtocol.commandsPath), ("POST", RemoteProtocol.contextBuilderPath):
            guard let command = try? JSONDecoder().decode(RemoteCommandRequest.self, from: request.body) else {
                return .response(.error(
                    .init(code: "invalid_command", message: "Invalid remote command request."),
                    status: 400
                ))
            }
            let endpoint: RemoteGatewayCommandEndpoint = components.path == RemoteProtocol.contextBuilderPath
                ? .contextBuilder
                : .commands
            return .request(.command(command, endpoint: endpoint))

        default:
            return .response(.error(
                .init(code: "not_found", message: "Remote endpoint not found."),
                status: 404
            ))
        }
    }

    private static func decodeTranscript(_ components: URLComponents) -> RemoteLegacyHTTPRequestDecodingResult {
        guard let sessionID = components.queryItems?
            .first(where: { $0.name == "session_id" })?
            .value
            .flatMap(UUID.init)
        else {
            return .response(.error(
                .init(code: "invalid_session", message: "A valid session_id is required."),
                status: 400
            ))
        }

        let after = components.queryItems?.first(where: { $0.name == "after" })?.value.flatMap(Int.init)
        let limit = components.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 100
        let includeDetails = components.queryItems?.first(where: { $0.name == "details" })?.value == "1"
        let itemIDValue = components.queryItems?.first(where: { $0.name == "item_id" })?.value
        if itemIDValue != nil, itemIDValue.flatMap(UUID.init) == nil {
            return .response(.error(
                .init(code: "invalid_transcript_item", message: "A valid item_id is required."),
                status: 400
            ))
        }

        let paging: RemoteTranscriptPageRequest
        if let itemID = itemIDValue.flatMap(UUID.init) {
            paging = .exactItem(itemID)
        } else if components.queryItems?.first(where: { $0.name == "order" })?.value == "recent" {
            let beforeValue = components.queryItems?.first(where: { $0.name == "before" })?.value
            do {
                paging = try .recentBackward(before: beforeValue.map(RemoteTranscriptCursorCodec.decode))
            } catch {
                return .response(.error(
                    .init(code: "invalid_transcript_cursor", message: "The transcript cursor is invalid."),
                    status: 400
                ))
            }
        } else {
            paging = .legacyForward(afterSequenceIndex: after)
        }

        return .request(.transcript(RemoteGatewayTranscriptRequest(
            sessionID: sessionID,
            paging: paging,
            limit: limit,
            includeDetails: includeDetails
        )))
    }
}

struct RemoteLegacyHTTPEncodedResponse {
    let status: Int
    let data: Data
}

enum RemoteLegacyHTTPResponseEncoder {
    static func encode(_ response: RemoteGatewayResponse) -> RemoteLegacyHTTPEncodedResponse {
        let encoder = JSONEncoder()
        let status: Int
        let contentType: String
        let body: Data

        switch response.content {
        case let .json(data):
            status = response.status
            contentType = "application/json; charset=utf-8"
            body = data
        case let .events(events):
            status = response.status
            contentType = "text/event-stream; charset=utf-8"
            let eventBody = events.map { event in
                let data = (try? encoder.encode(event)) ?? Data()
                return "id: \(event.sequence)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
            }.joined()
            body = Data((eventBody.isEmpty ? ": connected\n\n" : eventBody).utf8)
        case let .error(error):
            if let data = try? encoder.encode(error) {
                status = response.status
                contentType = "application/json; charset=utf-8"
                body = data
            } else {
                status = 500
                contentType = "application/json; charset=utf-8"
                body = Data("{\"code\":\"encoding_failed\",\"message\":\"The response could not be encoded.\"}".utf8)
            }
        }

        let header = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return RemoteLegacyHTTPEncodedResponse(status: status, data: data)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
    }
}

/// Legacy LAN HTTPS/SSE transport adapter.
///
/// This type owns only TLS listener lifecycle, bounded HTTP parsing, Bonjour,
/// and HTTP/SSE serialization. All application routing and authorization are
/// delegated to `RemoteGatewayRequestRouter`.
@MainActor
final class RemoteLegacyHTTPSGatewayAdapter {
    static let maximumBufferedRequestBytes = RemoteLegacyHTTPParser.maximumBufferedRequestBytes

    private let router: RemoteGatewayRequestRouter
    private let requestReceived: () -> Void
    private let successfulResponseSent: () -> Void

    private var listener: NWListener?
    private var bonjourService: NetService?
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]

    init(
        router: RemoteGatewayRequestRouter,
        requestReceived: @escaping () -> Void,
        successfulResponseSent: @escaping () -> Void
    ) {
        self.router = router
        self.requestReceived = requestReceived
        self.successfulResponseSent = successfulResponseSent
    }

    func start(
        identity: RemoteTLSIdentity,
        serviceName: String,
        desktopInstanceID: String
    ) async throws -> UInt16 {
        guard listener == nil else {
            throw RemoteGatewayError.listenerUnavailable
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw RemoteGatewaySecurityError.certificateUnavailable
        }
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            secIdentity
        )

        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UInt16, Error>) in
                var resumed = false
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor in
                        guard let self, let listener else { return }
                        switch state {
                        case .ready:
                            guard !resumed else { return }
                            resumed = true
                            guard let port = listener.port?.rawValue else {
                                continuation.resume(throwing: RemoteGatewayError.listenerUnavailable)
                                return
                            }
                            self.publishBonjour(
                                port: port,
                                serviceName: serviceName,
                                desktopInstanceID: desktopInstanceID
                            )
                            continuation.resume(returning: port)
                        case let .failed(error):
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(throwing: error)
                        case .cancelled:
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(throwing: RemoteGatewayError.listenerUnavailable)
                        default:
                            break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        self?.accept(connection)
                    }
                }
                listener.start(queue: .main)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        bonjourService?.stop()
        bonjourService = nil
        connectionBuffers.removeAll()
    }

    private func publishBonjour(
        port: UInt16,
        serviceName: String,
        desktopInstanceID: String
    ) {
        bonjourService?.stop()
        let service = NetService(
            domain: "local.",
            type: "_repoprompt-remote._tcp.",
            name: serviceName,
            port: Int32(port)
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "desktopInstanceID": desktopInstanceID.data(using: .utf8) ?? Data(),
            "protocol": "v1".data(using: .utf8) ?? Data()
        ]))
        service.schedule(in: .main, forMode: .common)
        service.publish(options: [.listenForConnections])
        bonjourService = service
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connectionBuffers[identifier] = Data()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    self.receive(on: connection)
                case .failed, .cancelled:
                    self.connectionBuffers.removeValue(forKey: ObjectIdentifier(connection))
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let connection else { return }
                let identifier = ObjectIdentifier(connection)
                if let data, !data.isEmpty {
                    self.connectionBuffers[identifier, default: Data()].append(data)
                    guard self.connectionBuffers[identifier, default: Data()].count <= Self.maximumBufferedRequestBytes else {
                        self.connectionBuffers.removeValue(forKey: identifier)
                        connection.cancel()
                        return
                    }
                    await self.processBufferedRequests(on: connection)
                }
                guard !isComplete, error == nil else {
                    self.connectionBuffers.removeValue(forKey: identifier)
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func processBufferedRequests(on connection: NWConnection) async {
        let identifier = ObjectIdentifier(connection)
        while var buffer = connectionBuffers[identifier],
              let request = RemoteLegacyHTTPParser.nextRequest(from: &buffer)
        {
            connectionBuffers[identifier] = buffer
            await handle(request, on: connection)
            if connectionBuffers[identifier] == nil { return }
        }
    }

    private func handle(_ request: RemoteLegacyHTTPRequest, on connection: NWConnection) async {
        requestReceived()
        let response: RemoteGatewayResponse = switch RemoteLegacyHTTPRequestDecoder.decode(request) {
        case let .request(routeRequest):
            await router.route(
                routeRequest,
                context: .legacyHTTPS(authorizationHeader: request.headers["authorization"])
            )
        case let .response(immediateResponse):
            immediateResponse
        }
        send(response, on: connection)
    }

    private func send(_ response: RemoteGatewayResponse, on connection: NWConnection) {
        let encoded = RemoteLegacyHTTPResponseEncoder.encode(response)
        if (200 ..< 300).contains(encoded.status) {
            successfulResponseSent()
        }
        connection.send(content: encoded.data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
