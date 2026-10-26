import Foundation

/// Synchronous observations only: never owns cancellation, routing, or settlement.
/// The sink runs under the lock to preserve ordering and make opt-out a barrier.
/// Sinks must not call back into this recorder. No task, timer, or disk writer is added.
enum MCPLifecycleDiagnostics {
    enum Phase: String {
        case requestEntered = "request_entered"
        case handlerReturning = "handler_returning"
        case providerEntered = "provider_entered"
        case providerReturning = "provider_returning"
        case requestCancellation = "request_cancellation"
        case deadlineCancellation = "deadline_cancellation"
        case settledDuringGrace = "settled_during_grace"
        case cleanupGraceExpired = "cleanup_grace_expired"
        case abandonedSettlement = "abandoned_settlement"
        case forceDisconnectedSettlement = "force_disconnected_settlement"
        case watchdogAbort = "watchdog_abort"
        case removalStarted = "removal_started"
        case ownedToolsCancelled = "owned_tools_cancelled"
        case connectionStopped = "connection_stopped"
        case removalFinished = "removal_finished"
    }

    struct Event {
        let connectionID: UUID
        let invocationID: UUID?
        let phase: Phase
        let sequence: UInt64

        /// Deliberately closed schema: no arbitrary attributes or caller strings.
        var data: [String: String] {
            var data = [
                "schema": "mcp_lifecycle_v1",
                "connection_id": connectionID.uuidString,
                "phase": phase.rawValue,
                "sequence": String(sequence)
            ]
            if let invocationID { data["invocation_id"] = invocationID.uuidString }
            return data
        }
    }

    static let shared = Recorder()

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence: UInt64 = 0
        private var sink: (@Sendable (Event) -> Void)?
        #if DEBUG
            private var captures: [UUID: [Event]] = [:]
            private var observers: [UUID: @Sendable (Event) -> Void] = [:]
        #endif

        func setSink(_ sink: (@Sendable (Event) -> Void)?) {
            lock.lock()
            defer { lock.unlock() }
            self.sink = sink
        }

        func record(_ phase: Phase, connectionID: UUID, invocationID: UUID? = nil) {
            lock.lock()
            defer { lock.unlock() }
            #if DEBUG
                let capturing = captures[connectionID] != nil
            #else
                let capturing = false
            #endif
            guard sink != nil || capturing else { return }
            sequence &+= 1
            let event = Event(connectionID: connectionID, invocationID: invocationID, phase: phase, sequence: sequence)
            #if DEBUG
                if capturing {
                    captures[connectionID, default: []].append(event)
                    if captures[connectionID, default: []].count > 128 {
                        captures[connectionID]?.removeFirst()
                    }
                    observers[connectionID]?(event)
                }
            #endif
            sink?(event)
        }

        #if DEBUG
            /// Scoped test capture; observer must not reenter the recorder.
            func beginCapture(connectionID: UUID, observer: (@Sendable (Event) -> Void)? = nil) {
                lock.lock()
                defer { lock.unlock() }
                captures[connectionID] = []
                observers[connectionID] = observer
            }

            func snapshot(connectionID: UUID) -> [Event] {
                lock.lock()
                defer { lock.unlock() }
                return captures[connectionID] ?? []
            }

            func endCapture(connectionID: UUID) {
                lock.lock()
                defer { lock.unlock() }
                captures.removeValue(forKey: connectionID)
                observers.removeValue(forKey: connectionID)
            }
        #endif
    }
}
