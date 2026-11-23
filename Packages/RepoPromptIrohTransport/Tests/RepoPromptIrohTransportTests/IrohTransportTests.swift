import Foundation
@testable import RepoPromptIrohTransport
import XCTest

final class IrohTransportTests: XCTestCase {
    func testHexRoundTripAndValidation() throws {
        let bytes = Data(0 ..< 32)
        XCTAssertEqual(try Data(spikeHex: bytes.spikeHex), bytes)
        XCTAssertThrowsError(try Data(spikeHex: "00"))
        XCTAssertThrowsError(try Data(spikeHex: String(repeating: "z", count: 64)))
    }

    func testStableEndpointIDUsesCallerSecret() throws {
        let secret = Data(repeating: 0x5A, count: 32)
        XCTAssertEqual(
            try endpointIdForSecret(secretKey: secret),
            try endpointIdForSecret(secretKey: secret)
        )
        XCTAssertNotEqual(
            try endpointIdForSecret(secretKey: secret),
            try endpointIdForSecret(secretKey: Data(repeating: 0xA5, count: 32))
        )
    }

    func testSwiftBridgeLoopbackEcho() async throws {
        let server = try await RepoPromptIrohSpike.start(
            secret: Data(repeating: 0x11, count: 32),
            relayEnabled: false,
            generation: 1
        )
        let client = try await RepoPromptIrohSpike.start(
            secret: Data(repeating: 0x22, count: 32),
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
        let accepted = try await server.accept()
        XCTAssertEqual(accepted.peerEndpointId, try client.snapshot().endpointId)
        XCTAssertEqual(connection.generation(), 2)

        let payload = Data("opaque Swift echo".utf8)
        let echoed = try await connection.sendFrame(payload: payload)
        XCTAssertEqual(echoed, payload)
        connection.close()
    }
}
