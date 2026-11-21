import XCTest
@testable import RepoPromptRemoteProtocol

final class RemoteTransportContractTests: XCTestCase {
    func testLegacyPairingFixtureDecodesWithoutExpiry() throws {
        let advertisement = try JSONDecoder().decode(
            RemotePairingAdvertisement.self,
            from: fixtureData(named: "protocol-v1-legacy-pairing")
        )

        XCTAssertEqual(advertisement.protocolVersion, 1)
        XCTAssertEqual(advertisement.desktopInstanceID, "legacy-desktop")
        XCTAssertEqual(advertisement.certificateSHA256, String(repeating: "a", count: 64))
        XCTAssertNil(advertisement.expiresAt)
    }

    func testPairingCodeVariantsAndIrohContractsRoundTrip() throws {
        let expiry = Date(timeIntervalSince1970: 2_000)
        let legacy = RemotePairingAdvertisement(
            desktopInstanceID: "desktop",
            serviceName: "RepoPrompt-desktop",
            host: "192.0.2.10",
            port: 8443,
            certificateSHA256: String(repeating: "a", count: 64),
            oneTimeSecret: "secret",
            expiresAt: expiry
        )
        let endpoint = RemoteIrohEndpointAddress(
            endpointID: String(repeating: "b", count: 64),
            directAddresses: ["192.0.2.10:4433", "[2001:db8::1]:4433"],
            relayURL: "https://relay.example"
        )
        let iroh = RemoteIrohPairingAdvertisement(
            desktopInstanceID: "desktop",
            server: endpoint,
            oneTimeSecret: "secret",
            expiresAt: expiry,
            legacyFallback: legacy
        )

        for code in [RemotePairingCode.legacyLAN(legacy), .iroh(iroh)] {
            XCTAssertEqual(
                try JSONDecoder().decode(RemotePairingCode.self, from: JSONEncoder().encode(code)),
                code
            )
        }

        let pairingRequest = RemoteIrohPairingRequest(
            desktopInstanceID: "desktop",
            expectedServerEndpointID: endpoint.endpointID,
            clientEndpointID: String(repeating: "c", count: 64),
            oneTimeSecret: "secret",
            deviceName: "Phone"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteIrohPairingRequest.self,
                from: JSONEncoder().encode(pairingRequest)
            ),
            pairingRequest
        )

        let bootstrap = RemoteTransportBootstrapResponse(
            desktopInstanceID: "desktop",
            server: endpoint
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteTransportBootstrapResponse.self,
                from: JSONEncoder().encode(bootstrap)
            ),
            bootstrap
        )

        let binding = RemoteIrohBindingRequest(
            desktopInstanceID: "desktop",
            deviceID: "device",
            expectedServerEndpointID: endpoint.endpointID,
            clientEndpointID: pairingRequest.clientEndpointID
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteIrohBindingRequest.self, from: JSONEncoder().encode(binding)),
            binding
        )

        let pairingResponse = RemoteIrohPairingResponse(
            pairingResponse: RemotePairingResponse(
                desktop: RemoteDesktopSummary(
                    instanceID: "desktop",
                    displayName: "Mac",
                    appVersion: "test",
                    isAvailable: true
                ),
                deviceID: "device",
                credential: "credential"
            ),
            serverEndpointID: endpoint.endpointID,
            clientEndpointID: pairingRequest.clientEndpointID
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteIrohPairingResponse.self,
                from: JSONEncoder().encode(pairingResponse)
            ),
            pairingResponse
        )

        let bindingResponse = RemoteIrohBindingResponse(
            desktopInstanceID: "desktop",
            deviceID: "device",
            serverEndpointID: endpoint.endpointID,
            clientEndpointID: pairingRequest.clientEndpointID
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteIrohBindingResponse.self,
                from: JSONEncoder().encode(bindingResponse)
            ),
            bindingResponse
        )
    }

    func testEndpointAddressBoundsDirectAddressesOnProductionAndDecode() throws {
        let addresses = (0 ..< 6).map { "192.0.2.\($0):4433" }
        let produced = RemoteIrohEndpointAddress(endpointID: "endpoint", directAddresses: addresses)
        XCTAssertEqual(produced.directAddresses, Array(addresses.prefix(4)))

        let encoded = try JSONSerialization.data(withJSONObject: [
            "endpointID": "endpoint",
            "directAddresses": addresses
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteIrohEndpointAddress.self, from: encoded))
    }

    func testEveryWireFrameKindAndRPCOperationRoundTrips() throws {
        for kind in RemoteWireFrameKind.allCases {
            let frame = RemoteWireFrame(kind: kind, messageID: UUID(), payload: Data(kind.rawValue.utf8))
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteWireFrame.self, from: JSONEncoder().encode(frame)),
                frame
            )
        }

        for operation in RemoteRPCOperation.allCases {
            let request = RemoteRPCRequest(operation: operation, payload: Data(operation.rawValue.utf8))
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteRPCRequest.self, from: JSONEncoder().encode(request)),
                request
            )
        }
    }

    func testTypedWirePayloadValidationAndLimits() throws {
        let heartbeat = RemoteHeartbeat(sentAt: Date(timeIntervalSince1970: 1))
        let frame = try RemoteWireFrame(kind: .heartbeat, encoding: heartbeat)
        XCTAssertEqual(
            try frame.decodedPayload(as: RemoteHeartbeat.self, expectedKind: .heartbeat),
            heartbeat
        )
        XCTAssertNoThrow(try frame.validateEncodedLimit(direction: .serverEvent))

        XCTAssertThrowsError(
            try frame.decodedPayload(as: RemoteHeartbeat.self, expectedKind: .event)
        ) { error in
            XCTAssertEqual(
                error as? RemoteWireContractError,
                .unexpectedKind(expected: .event, actual: .heartbeat)
            )
        }

        let malformed = RemoteWireFrame(kind: .heartbeat, payload: Data("not-json".utf8))
        XCTAssertThrowsError(
            try malformed.decodedPayload(as: RemoteHeartbeat.self, expectedKind: .heartbeat)
        ) { error in
            XCTAssertEqual(error as? RemoteWireContractError, .malformedPayload)
        }

        let future = RemoteWireFrame(wireVersion: 2, kind: .heartbeat)
        XCTAssertThrowsError(try future.validateEncodedLimit(direction: .serverEvent)) { error in
            XCTAssertEqual(error as? RemoteWireContractError, .unsupportedWireVersion(2))
        }

        let oversized = RemoteWireFrame(
            kind: .rpcRequest,
            payload: Data(repeating: 0xFF, count: RemoteWireProtocol.maximumClientFrameBytes)
        )
        XCTAssertThrowsError(try oversized.validateEncodedLimit(direction: .clientToServer)) { error in
            guard case let .frameTooLarge(actual, maximum) = error as? RemoteWireContractError else {
                return XCTFail("Expected an encoded frame limit error")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, RemoteWireProtocol.maximumClientFrameBytes)
        }
        XCTAssertNoThrow(try oversized.validateEncodedLimit(direction: .serverResponse))
    }

    func testAttachmentChunkFitsNestedIrohClientFrameAndRoundTrips() throws {
        let chunk = RemoteAttachmentChunk(
            submissionID: UUID(), attachmentID: UUID(), fileName: "Screenshot.png",
            fileSize: RemoteAttachmentLimits.maxChunkBytes, offset: 0,
            bytes: Data(repeating: 255, count: RemoteAttachmentLimits.maxChunkBytes)
        )
        let request = RemoteCommandRequest(operation: .uploadAttachment, attachmentChunk: chunk)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let body = try encoder.encode(request)
        let rpc = RemoteRPCRequest(operation: .command, payload: body)
        let frame = try RemoteWireFrame(kind: .rpcRequest, messageID: UUID(), encoding: rpc)
        try frame.validateEncodedLimit(direction: .clientToServer)
        let encoded = try encoder.encode(frame)
        XCTAssertLessThan(encoded.count, RemoteWireProtocol.maximumClientFrameBytes)
        XCTAssertEqual(try decoder.decode(RemoteCommandRequest.self, from: body), request)

        let oldCatalog = Data(#"{"supportsStartSelection":true,"supportsSessionConfiguration":true}"#.utf8)
        XCTAssertNil(try decoder.decode(RemoteCatalogMetadata.self, from: oldCatalog).supportsAttachments)
    }

    func testRPCResponseRequiresExactlyOneResultOrError() throws {
        let success = RemoteRPCResponse(result: Data("ok".utf8))
        let failure = RemoteRPCResponse(error: RemoteErrorResponse(
            code: "snapshot_required",
            message: "Refresh the snapshot.",
            retryable: true
        ))
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteRPCResponse.self, from: JSONEncoder().encode(success)),
            success
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteRPCResponse.self, from: JSONEncoder().encode(failure)),
            failure
        )

        for object: [String: Any] in [
            [:],
            [
                "result": Data().base64EncodedString(),
                "error": ["code": "failed", "message": "failed", "retryable": false]
            ]
        ] {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(RemoteRPCResponse.self, from: data))
        }
    }

    func testTranscriptRPCPagingModeIsAdditiveAndLegacyPayloadStillDecodes() throws {
        let sessionID = UUID()
        for mode in [RemoteTranscriptRPCPagingMode.recentBackward, .legacyForward] {
            let request = RemoteTranscriptRPCRequest(
                sessionID: sessionID, pagingMode: mode, limit: 25
            )
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteTranscriptRPCRequest.self, from: JSONEncoder().encode(request)),
                request
            )
        }

        let legacyPayload: [String: Any] = [
            "sessionID": sessionID.uuidString,
            "limit": 100,
            "includeDetails": false
        ]
        let decoded = try JSONDecoder().decode(
            RemoteTranscriptRPCRequest.self,
            from: JSONSerialization.data(withJSONObject: legacyPayload)
        )
        XCTAssertNil(decoded.pagingMode)
    }

    func testSubscriptionAtomicallyBridgesReplayAndLiveDelivery() async throws {
        let buffer = RemoteEventReplayBuffer(capacity: 8)
        let desktopID = "desktop"
        _ = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .sessionCreated))
        let second = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .runStarted))

        let result = await buffer.subscribe(after: 1, desktopInstanceID: desktopID)
        guard case let .subscription(subscription) = result else {
            return XCTFail("Expected a replay-plus-live subscription")
        }
        XCTAssertEqual(subscription.initialEvents, [second])

        let third = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .runProgressed))
        var iterator = subscription.liveEvents.makeAsyncIterator()
        let deliveredThird = await iterator.next()
        XCTAssertEqual(deliveredThird, third)

        await buffer.finishSubscriptions()
        let finishedValue = await iterator.next()
        XCTAssertNil(finishedValue)
    }

    func testSubscriptionRejectsStaleCursorBeforeRegistration() async {
        let buffer = RemoteEventReplayBuffer(capacity: 2)
        for _ in 0 ..< 3 {
            _ = await buffer.append(RemoteEvent(desktopInstanceID: "desktop", type: .sessionUpdated))
        }

        let result = await buffer.subscribe(after: 0, desktopInstanceID: "desktop")
        guard case .snapshotRequired = result else {
            return XCTFail("Expected a stale subscription to require a snapshot")
        }
    }

    func testStalledSubscriptionIsBoundedAndTerminatesAtFirstDroppedEvent() async {
        let buffer = RemoteEventReplayBuffer(capacity: 2)
        let result = await buffer.subscribe(after: nil, desktopInstanceID: "desktop")
        guard case let .subscription(subscription) = result else {
            return XCTFail("Expected a subscription")
        }

        let first = await buffer.append(RemoteEvent(desktopInstanceID: "desktop", type: .sessionCreated))
        let second = await buffer.append(RemoteEvent(desktopInstanceID: "desktop", type: .runStarted))
        let third = await buffer.append(RemoteEvent(desktopInstanceID: "desktop", type: .runProgressed))

        var iterator = subscription.liveEvents.makeAsyncIterator()
        let deliveredFirst = await iterator.next()
        let deliveredSecond = await iterator.next()
        let finishedValue = await iterator.next()
        XCTAssertEqual(deliveredFirst, first)
        XCTAssertEqual(deliveredSecond, second)
        XCTAssertNil(finishedValue)

        // Reconnecting from the last contiguous cursor recovers the dropped event.
        let replay = await buffer.replay(after: second.sequence, desktopInstanceID: "desktop")
        XCTAssertEqual(replay, .events([third]))
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
