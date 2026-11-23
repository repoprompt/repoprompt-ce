import Darwin
import Foundation
import RepoPromptIrohTransport

@main
struct IrohTransportSpikeMac {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        switch command {
        case "--self-test":
            try await selfTest()
        case "listen":
            try await listen(arguments: Array(arguments.dropFirst()))
        case "connect":
            try await connect(arguments: Array(arguments.dropFirst()))
        default:
            printUsage()
            throw SpikeCLIError.invalidArguments
        }
    }

    private static func selfTest() async throws {
        let serverSecret = Data(repeating: 0x31, count: 32)
        let clientSecret = Data(repeating: 0x32, count: 32)
        let stableID = try endpointIdForSecret(secretKey: serverSecret)
        guard stableID == (try endpointIdForSecret(secretKey: serverSecret)) else {
            throw SpikeCLIError.validation("stable endpoint ID check failed")
        }

        let server = try await RepoPromptIrohSpike.start(
            secret: serverSecret,
            relayEnabled: false,
            generation: 1
        )
        let client = try await RepoPromptIrohSpike.start(
            secret: clientSecret,
            relayEnabled: false,
            generation: 2
        )
        defer {
            Task {
                try? await client.shutdown()
                try? await server.shutdown()
            }
        }

        let connection = try await client.connect(
            addressJson: try server.snapshot().addressJson,
            alpn: RepoPromptIrohSpike.alpn
        )
        async let incoming = server.accept()
        let accepted = try await incoming
        guard accepted.peerEndpointId == (try client.snapshot().endpointId) else {
            throw SpikeCLIError.validation("authenticated peer ID mismatch")
        }

        for sequence in 0 ..< 10_000 {
            var bigEndian = UInt64(sequence).bigEndian
            let payload = withUnsafeBytes(of: &bigEndian) { Data($0) }
            let echoed = try await connection.sendFrame(payload: payload)
            guard echoed == payload else {
                throw SpikeCLIError.validation("echo corruption at sequence \(sequence)")
            }
        }

        do {
            _ = try await connection.sendFrame(
                payload: Data(count: RepoPromptIrohSpike.maximumFrameBytes + 1)
            )
            throw SpikeCLIError.validation("oversized frame was accepted")
        } catch let error as TransportError {
            guard error.localizedDescription.contains("exceeds") else { throw error }
        }

        print("SELF_TEST_OK messages=10000 endpoint=\(stableID) path=\(connection.pathSummary())")
        connection.close()
        try await client.shutdown()
        try await server.shutdown()
    }

    private static func listen(arguments: [String]) async throws {
        let options = try Options(arguments)
        let endpoint = try await RepoPromptIrohSpike.start(
            secret: options.secret,
            relayEnabled: options.relayEnabled,
            generation: 1
        )
        let snapshot = options.relayEnabled
            ? try await endpoint.waitUntilOnline(timeoutMillis: 30_000)
            : try endpoint.snapshot()
        print("endpoint_id=\(snapshot.endpointId)")
        print("address_json=\(snapshot.addressJson)")
        print("relay_enabled=\(snapshot.relayEnabled)")
        print("waiting for opaque echo connections; Ctrl-C to stop")
        while true {
            let incoming = try await endpoint.accept()
            print("accepted peer=\(incoming.peerEndpointId) generation=\(incoming.generation) path=\(incoming.pathSummary)")
        }
    }

    private static func connect(arguments: [String]) async throws {
        let options = try Options(arguments, requiresAddress: true)
        let endpoint = try await RepoPromptIrohSpike.start(
            secret: options.secret,
            relayEnabled: options.relayEnabled,
            generation: 1
        )
        let localEndpointID = try endpoint.snapshot().endpointId
        let connection = try await endpoint.connect(
            addressJson: options.addressJSON!,
            alpn: RepoPromptIrohSpike.alpn
        )
        let started = ContinuousClock.now
        for sequence in 0 ..< options.count {
            let payload = Data("opaque-\(sequence)".utf8)
            guard try await connection.sendFrame(payload: payload) == payload else {
                throw SpikeCLIError.validation("echo corruption at sequence \(sequence)")
            }
        }
        let duration = ContinuousClock.now - started
        print("ECHO_OK messages=\(options.count) local=\(localEndpointID) peer=\(connection.peerEndpointId()) path=\(connection.pathSummary()) duration=\(duration)")
        connection.close()
        try await endpoint.shutdown()
    }

    private static func printUsage() {
        print("""
        Usage:
          repoprompt-iroh-spike --self-test
          repoprompt-iroh-spike listen --secret-stdin [--no-relay]
          repoprompt-iroh-spike connect --secret-stdin --address <json> [--count 10000] [--no-relay]

        Secrets are read without echo from an interactive terminal, or as one line on standard input.
        They are passed only to endpoint startup; this spike never persists or prints them.
        """)
    }
}

private struct Options {
    let secret: Data
    let addressJSON: String?
    let count: Int
    let relayEnabled: Bool

    init(_ arguments: [String], requiresAddress: Bool = false) throws {
        var readsSecretFromStandardInput = false
        var address: String?
        var count = 10_000
        var relayEnabled = true
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--secret-stdin":
                readsSecretFromStandardInput = true
                index += 1
            case "--address" where index + 1 < arguments.count:
                address = arguments[index + 1]
                index += 2
            case "--count" where index + 1 < arguments.count:
                guard let value = Int(arguments[index + 1]), value > 0 else {
                    throw SpikeCLIError.invalidArguments
                }
                count = value
                index += 2
            case "--no-relay":
                relayEnabled = false
                index += 1
            default:
                throw SpikeCLIError.invalidArguments
            }
        }
        guard readsSecretFromStandardInput else { throw SpikeCLIError.missingSecret }
        if requiresAddress, address == nil { throw SpikeCLIError.missingAddress }
        secret = try Data(spikeHex: readSecretFromStandardInput())
        addressJSON = address
        self.count = count
        self.relayEnabled = relayEnabled
    }
}

private func readSecretFromStandardInput() throws -> String {
    if isatty(STDIN_FILENO) == 1 {
        guard let secret = getpass("Endpoint secret (64 hex, input hidden): ") else {
            throw SpikeCLIError.missingSecret
        }
        return String(cString: secret)
    }
    guard let secret = readLine(strippingNewline: true) else {
        throw SpikeCLIError.missingSecret
    }
    return secret
}

private enum SpikeCLIError: Error, LocalizedError {
    case invalidArguments
    case missingSecret
    case missingAddress
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid arguments."
        case .missingSecret: "--secret-stdin is required."
        case .missingAddress: "--address is required."
        case let .validation(message): message
        }
    }
}
