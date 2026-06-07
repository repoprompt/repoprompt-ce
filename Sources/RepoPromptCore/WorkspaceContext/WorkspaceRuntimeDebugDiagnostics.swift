import Dispatch
import Foundation

/// Debug-only compatibility surface for moved runtime milestones. Production
/// diagnostics flow through the injected `WorkspaceRuntimeDiagnosticsSink`.
package enum WorkspaceRuntimeDebugLog {
    package static func timestampMSIfEnabled() -> UInt64? {
        guard WorkspaceRuntimePerf.activeSink != nil else { return nil }
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    package static func event(_ name: String, fields: [String: String] = [:]) {
        WorkspaceRuntimePerf.activeSink?.record(WorkspaceRuntimeDiagnosticEvent(
            subsystem: "workspace",
            name: name,
            kind: .lifecycle,
            correlationID: WorkspaceRuntimePerf.currentLifecycleCorrelation?.id,
            fields: fields
        ))
    }

    package static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    package static func formatElapsedMS(since start: UInt64) -> String {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        return String(now >= start ? now - start : 0)
    }
}

package enum WorkspaceRootLoadDiagnosticFields {
    package static func rootRecordCreatedFields(forPath _: String) -> [String: String] {
        [:]
    }

    package static func firstPreparedChunkFields(forPath _: String) -> [String: String] {
        [:]
    }
}
