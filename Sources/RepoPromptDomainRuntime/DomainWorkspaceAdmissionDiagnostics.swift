import Foundation

/// Diagnostic-only evidence. No document, digest, path, name, origin payload, or error text
/// enters this schema. Working/saved revisions are opaque document versions, not content hashes.
package struct DomainWorkspaceTransitionDiagnostic: Codable, Equatable {
    package enum Transition: String, Codable {
        case reconstructed, dirtySet, dirtyCleared
        case saveScheduled, saveStarted, saveCompleted, saveFailed, saveCancelled, saveSuperseded
        case admissionAttempted, admissionRejected, admissionPassed
    }

    package enum Operation: String, Codable {
        case reconstruction, workingCommit, savedCommit, externalReload, saveWorkspace, agentAdmission
    }

    package enum AdmissionState: String, Codable {
        case clean, dirtySaveInFlight, dirtyWithoutLiveSave, unhealthy, unavailable

        package static func classify(health: DomainAuthorityHealth?, revisions: DomainRevisionState?, pendingSaveCount: Int) -> Self {
            guard let health, let revisions else { return .unavailable }
            guard health.acceptsMutations else { return .unhealthy }
            guard revisions.dirtyRevision != nil else { return .clean }
            return pendingSaveCount > 0 ? .dirtySaveInFlight : .dirtyWithoutLiveSave
        }
    }

    package struct DirtyOrigin: Codable, Equatable {
        package let revision: UInt64
        package let operation: Operation
        package let operationID: UUID?
    }

    package enum SaveState: String, Codable {
        case none, scheduled, started
    }

    package struct LastSave: Codable, Equatable {
        package let generation: UInt64
        package let operationID: UUID
        package let attemptedRevision: UInt64?
        package let transition: Transition
        package let error: DomainCommandErrorCode?
    }

    package let runtimeID: UUID
    package let lifecycleGeneration: UInt64
    package let workspaceID: UUID
    package let sequence: UInt64
    package let uptimeNanoseconds: UInt64
    package let catalogRevision: UInt64
    package let snapshotSequence: UInt64
    package let revisions: DomainRevisionState?
    package let workingDiffersFromSaved: Bool?
    package let dirtyOrigin: DirtyOrigin?
    package let pendingSaveState: SaveState
    package let lastSave: LastSave?
    package let pendingSaveCount: Int
    package let saveGeneration: UInt64?
    package let transition: Transition
    package let operation: Operation
    package let operationID: UUID?
    package let admissionState: AdmissionState
    package let error: DomainCommandErrorCode?

    /// A bounded, allowlisted tuple suitable for NSError/MCP text; never stringify an Error.
    package var encodedEvidence: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    package var rejectionDescription: String {
        switch admissionState {
        case .dirtySaveInFlight:
            "Canonical workspace has unsaved changes and a save command is in flight; Agent admission remains blocked."
        case .dirtyWithoutLiveSave:
            "Canonical workspace has unsaved changes with no live save command; Agent admission remains blocked. Intentional edits versus interrupted persistence is not yet classified."
        case .unhealthy:
            "Canonical workspace authority is not mutation-safe; Agent admission remains blocked."
        case .unavailable:
            "Canonical workspace snapshot is unavailable; Agent admission remains blocked."
        case .clean:
            "Canonical workspace passed the clean-state admission guard; any later failure belongs to a subsequent boundary."
        }
    }
}

package struct DomainWorkspaceAdmissionSnapshot {
    package let snapshot: DomainWorkspaceSnapshot?
    package let diagnostic: DomainWorkspaceTransitionDiagnostic
}

/// Fixed global retention, not a per-workspace unbounded log. Evidence older than this ring
/// is unavailable; retained origins live with the canonical record, not in a second authority.
struct DomainWorkspaceTransitionBuffer {
    static let capacity = 128
    private(set) var entries: [DomainWorkspaceTransitionDiagnostic] = []
    private(set) var sequence: UInt64 = 0

    mutating func nextSequence() -> UInt64 {
        sequence &+= 1
        return sequence
    }

    mutating func append(_ entry: DomainWorkspaceTransitionDiagnostic) {
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append(entry)
    }
}
