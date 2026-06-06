import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

actor MCPStreamableHTTPListener {
    typealias RequestHandler = @Sendable (MCPStreamableHTTPRequest) async -> MCPStreamableHTTPResponse

    struct Configuration: Equatable {
        var bindAddress: String
        var port: Int

        init(bindAddress: String, port: Int) {
            self.bindAddress = bindAddress
            self.port = port
        }
    }

    private let configuration: Configuration
    private let requestHandler: RequestHandler
    private let logger: Logger
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(configuration: Configuration, logger: Logger? = nil, requestHandler: @escaping RequestHandler) {
        self.configuration = configuration
        self.requestHandler = requestHandler
        self.logger = logger ?? Logger(label: "com.repoprompt.mcp.http.listener")
    }

    func start() async throws {
        guard channel == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [requestHandler, logger] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(MCPStreamableHTTPChannelHandler(
                        requestHandler: requestHandler,
                        logger: logger
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: false)

        do {
            channel = try await bootstrap.bind(host: configuration.bindAddress, port: configuration.port).get()
            logger.notice("Network MCP HTTP listener bound to \(configuration.bindAddress):\(configuration.port)")
        } catch {
            self.group = nil
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        let channel = channel
        let group = group
        self.channel = nil
        self.group = nil

        if let channel {
            try? await channel.close().get()
        }
        if let group {
            try? await group.shutdownGracefully()
        }
    }
}

private final class MCPStreamableHTTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let requestHandler: MCPStreamableHTTPListener.RequestHandler
    private let logger: Logger
    private var currentHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private let maxBodyBytes = 8 * 1024 * 1024

    init(requestHandler: @escaping MCPStreamableHTTPListener.RequestHandler, logger: Logger) {
        self.requestHandler = requestHandler
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            currentHead = head
            bodyBuffer.clear()
        case var .body(part):
            if bodyBuffer.readableBytes + part.readableBytes <= maxBodyBytes {
                bodyBuffer.writeBuffer(&part)
            }
        case .end:
            guard let head = currentHead else {
                writeResponse(.error(statusCode: 400, message: "Missing HTTP request head"), context: context)
                return
            }
            let body = Data(bodyBuffer.readBytes(length: bodyBuffer.readableBytes) ?? [])
            currentHead = nil
            bodyBuffer.clear()
            let request = makeRequest(head: head, body: body, context: context)
            Task { [requestHandler] in
                let response = await requestHandler(request)
                context.eventLoop.execute { [weak self] in
                    self?.writeResponse(response, context: context)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("Network MCP HTTP channel error: \(String(describing: error))")
        context.close(promise: nil)
    }

    private func makeRequest(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) -> MCPStreamableHTTPRequest {
        var headers: [String: String] = [:]
        for header in head.headers {
            headers[header.name] = header.value
        }
        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? head.uri
        return MCPStreamableHTTPRequest(
            method: head.method.rawValue,
            path: path,
            headers: headers,
            body: body,
            remoteAddress: context.channel.remoteAddress?.description ?? "unknown"
        )
    }

    private func writeResponse(_ response: MCPStreamableHTTPResponse, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.replaceOrAdd(name: name, value: value)
        }
        if let body = response.body {
            headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        } else {
            headers.replaceOrAdd(name: "Content-Length", value: "0")
        }
        if headers["Connection"].isEmpty {
            headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        }

        let status = HTTPResponseStatus(statusCode: response.statusCode)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if let body = response.body, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private extension EventLoopGroup {
    func shutdownGracefully() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
