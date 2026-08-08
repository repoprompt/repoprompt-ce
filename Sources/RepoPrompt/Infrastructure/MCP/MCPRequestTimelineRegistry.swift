#if DEBUG || MCP_LATENCY_DIAGNOSTICS
    import Foundation
    import RepoPromptShared

    /// DEBUG diagnostics registry that joins raw transport frames to SDK tool handlers without
    /// modifying JSON-RPC payloads. The registry is lock-based because frame acceptance occurs
    /// on the transport read queue while SDK callbacks execute on cooperative tasks.
    final class MCPRequestTimelineRegistry: @unchecked Sendable {
        static let shared = MCPRequestTimelineRegistry()

        struct RecordedMessage {
            let metadata: JSONRPCBridgeMessageMetadata
            let identity: MCPRequestTimelineIdentity
        }

        private struct ConnectionKey: Hashable {
            let connectionID: String
            let generation: UInt64
        }

        private struct ResponseKey: Hashable {
            let connection: ConnectionKey
            let id: JSONRPCBridgeID
        }

        private struct PendingRequest {
            let identity: MCPRequestTimelineIdentity
        }

        private let lock = NSLock()
        private var nextOrdinalByConnection: [ConnectionKey: UInt64] = [:]
        private var pendingToolRequestsByConnection: [ConnectionKey: [PendingRequest]] = [:]
        private var identitiesByResponseKey: [ResponseKey: MCPRequestTimelineIdentity] = [:]

        init() {}

        func recordAcceptedFrame(
            _ frame: Data,
            connectionID: String,
            correlationConnectionID: String,
            connectionGeneration: UInt64
        ) -> [RecordedMessage] {
            let summaries = JSONRPCBridgeFrameInspector.inspectPermissively(
                frame,
                direction: .clientToServer
            )
            guard !summaries.isEmpty else { return [] }

            let key = ConnectionKey(connectionID: connectionID, generation: connectionGeneration)
            lock.lock()
            defer { lock.unlock() }

            var nextOrdinal = nextOrdinalByConnection[key] ?? 0
            var recorded: [RecordedMessage] = []
            for summary in summaries {
                var ordinal = summary.requestOrdinal
                if summary.kind == .request, summary.id != nil {
                    nextOrdinal &+= 1
                    ordinal = ordinal ?? nextOrdinal
                }
                let metadata = JSONRPCBridgeMessageMetadata(
                    kind: summary.kind,
                    id: summary.id,
                    method: summary.method,
                    tool: summary.tool,
                    requestOrdinal: ordinal,
                    appInvocationID: summary.appInvocationID
                )
                let identity = MCPRequestTimelineIdentity(
                    jsonRPCRequestID: summary.id,
                    connectionID: correlationConnectionID,
                    connectionGeneration: connectionGeneration,
                    appInvocationID: summary.appInvocationID,
                    requestOrdinal: ordinal
                )
                recorded.append(RecordedMessage(metadata: metadata, identity: identity))

                if summary.kind == .request, let id = summary.id, id != .null {
                    identitiesByResponseKey[ResponseKey(connection: key, id: id)] = identity
                    if summary.method == "tools/call" {
                        pendingToolRequestsByConnection[key, default: []].append(PendingRequest(
                            identity: identity
                        ))
                    }
                }
            }
            nextOrdinalByConnection[key] = nextOrdinal
            trimIfNeeded()
            return recorded
        }

        func claimToolRequest(
            connectionID: String,
            appInvocationID: UUID
        ) -> MCPRequestTimelineIdentity? {
            let canonicalInvocationID = appInvocationID.uuidString
            lock.lock()
            defer { lock.unlock() }

            var matches: [(ConnectionKey, Int)] = []
            for (key, pending) in pendingToolRequestsByConnection where key.connectionID == connectionID {
                for index in pending.indices {
                    let identity = pending[index].identity
                    guard identity.appInvocationID == canonicalInvocationID,
                          identity.isCompleteLatencyEvidenceIdentity
                    else {
                        continue
                    }
                    matches.append((key, index))
                }
            }
            guard matches.count == 1,
                  let (key, index) = matches.first,
                  var pending = pendingToolRequestsByConnection[key]
            else {
                return nil
            }
            let request = pending.remove(at: index)
            pendingToolRequestsByConnection[key] = pending
            return request.identity
        }

        func updateResponseIdentity(to resolvedIdentity: MCPRequestTimelineIdentity) {
            guard let requestID = resolvedIdentity.jsonRPCRequestID else { return }
            lock.lock()
            defer { lock.unlock() }
            let responseKeys: [ResponseKey] = identitiesByResponseKey.compactMap { key, identity in
                guard key.id == requestID,
                      identity.connectionID == resolvedIdentity.connectionID,
                      identity.connectionGeneration == resolvedIdentity.connectionGeneration,
                      identity.requestOrdinal == resolvedIdentity.requestOrdinal
                else { return nil }
                return key
            }
            for key in responseKeys {
                identitiesByResponseKey[key] = resolvedIdentity
            }
        }

        func recordedResponses(
            in frame: Data,
            connectionID: String,
            connectionGeneration: UInt64
        ) -> [RecordedMessage] {
            let summaries = JSONRPCBridgeFrameInspector.inspectPermissively(
                frame,
                direction: .serverToClient
            )
            let key = ConnectionKey(connectionID: connectionID, generation: connectionGeneration)
            lock.lock()
            defer { lock.unlock() }
            return summaries.compactMap { summary in
                guard let id = summary.id,
                      let identity = identitiesByResponseKey[ResponseKey(connection: key, id: id)]
                else { return nil }
                let metadata = JSONRPCBridgeMessageMetadata(
                    kind: summary.kind,
                    id: summary.id,
                    method: summary.method,
                    tool: summary.tool,
                    requestOrdinal: identity.requestOrdinal
                )
                return RecordedMessage(metadata: metadata, identity: identity)
            }
        }

        func removeConnection(connectionID: String, connectionGeneration: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            let connection = ConnectionKey(
                connectionID: connectionID,
                generation: connectionGeneration
            )
            nextOrdinalByConnection.removeValue(forKey: connection)
            pendingToolRequestsByConnection.removeValue(forKey: connection)
            identitiesByResponseKey = identitiesByResponseKey.filter { $0.key.connection != connection }
        }

        func completeResponses(
            _ messages: [RecordedMessage],
            connectionID: String,
            connectionGeneration: UInt64
        ) {
            lock.lock()
            defer { lock.unlock() }
            let connection = ConnectionKey(
                connectionID: connectionID,
                generation: connectionGeneration
            )
            for message in messages {
                guard let id = message.identity.jsonRPCRequestID else { continue }
                identitiesByResponseKey.removeValue(forKey: ResponseKey(
                    connection: connection,
                    id: id
                ))
            }
        }

        private func trimIfNeeded() {
            let maximumEntries = 4096
            if identitiesByResponseKey.count > maximumEntries {
                identitiesByResponseKey.removeAll(keepingCapacity: true)
            }
            for key in Array(pendingToolRequestsByConnection.keys) {
                guard var pending = pendingToolRequestsByConnection[key],
                      pending.count > maximumEntries
                else { continue }
                pending.removeFirst(pending.count - maximumEntries)
                pendingToolRequestsByConnection[key] = pending
            }
        }
    }
#endif
