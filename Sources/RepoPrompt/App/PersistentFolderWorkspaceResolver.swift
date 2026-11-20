import Foundation
import RepoPromptDomainRuntime
import RepoPromptWorkspaceCore

/// The shared authority-only half of Open Folder. No window, activation or recency mutation.
@MainActor
enum PersistentFolderWorkspaceResolver {
    struct Resolution {
        let workspace: WorkspaceModel
        let provenance: PersistentFolderOpenProvenance
        let outcome: DomainCommandOutcome
        let snapshot: DomainWorkspaceSnapshot
    }

    enum Failure: LocalizedError {
        case snapshot(Error)
        case command(UUID, Error)
        case outcome(UUID, DomainCommandOutcome)
        case projection(Error)
        var underlying: Error {
            switch self {
            case let .snapshot(error), let .command(_, error), let .projection(error): error
            case let .outcome(_, outcome): DomainWorkspaceAuthorityOperationError(outcome: outcome)
            }
        }

        var errorDescription: String? {
            underlying.localizedDescription
        }
    }

    static let panelTitle = "Open Folder"
    static let panelMessage = "Choose a folder to open. If it matches an existing workspace root, that workspace will reopen."

    static func resolve(
        folderURL: URL,
        client: DomainWorkspaceAuthorityClient,
        fileURL: (WorkspaceModel) -> URL,
        afterSnapshot: () async -> Void = {},
        operationID: UUID = UUID()
    ) async throws -> Resolution {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &directory), directory.boolValue else {
            throw PersistentFolderOpenError.invalidFolder
        }
        let authoritySnapshot = await client.snapshot()
        await afterSnapshot()

        try Task.checkCancellation()
        let candidates: [WorkspaceModel]
        do {
            candidates = try authoritySnapshot.workspaces.map {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: $0.document.documentBytes, fileURL: $0.document.fileURL)
            }
        } catch { throw Failure.snapshot(PersistentFolderOpenError.authoritySnapshotUnavailable) }
        let workspace = WorkspaceModel(
            name: uniqueName(
                baseName: folderURL.lastPathComponent,
                in: candidates
            ),
            repoPaths: [folderURL.path],
            isSavedWorkspace: true
        )
        let fileURL = fileURL(workspace)
        guard let canonicalRootPath = WorkspaceRootSetKey(paths: [folderURL.path])
            .normalizedPaths.first?.lowercased()
        else {
            throw PersistentFolderOpenError.invalidFolder
        }
        let outcome: DomainCommandOutcome
        do {
            outcome = try await client.resolveOrCreatePersistentWorkspace(workspace, fileURL: fileURL, canonicalRootPath: canonicalRootPath, operationID: operationID)
        } catch { throw Failure.command(workspace.id, error) }
        guard outcome.disposition == .applied || outcome.disposition == .unchanged || outcome.disposition == .deduplicated,
              let outcomeWorkspace = outcome.workspace else { throw Failure.outcome(workspace.id, outcome) }

        let provenance: PersistentFolderOpenProvenance
        switch outcome.exactRootResolution {
        case .created:
            provenance = .created
        case .reused:
            provenance = .reused
        case .recoveryBlocked, nil:
            throw Failure.outcome(workspace.id, outcome)
        }

        let canonical: WorkspaceModel
        do {
            canonical = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: outcomeWorkspace.document.documentBytes,
                fileURL: outcomeWorkspace.document.fileURL
            )
        } catch { throw Failure.projection(error) }

        return Resolution(workspace: canonical, provenance: provenance, outcome: outcome, snapshot: outcomeWorkspace)
    }

    static func resolve(folderURL: URL) async throws -> Resolution {
        let runtime = AppDomainRuntimeComposition.shared.runtime
        let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: 0, metadataPathPolicy: runtime.configuration.metadataPathPolicy)
        let root = runtime.configuration.workspaceStorageDirectory
        let resolution = try await resolve(folderURL: folderURL.standardizedFileURL, client: client, fileURL: {
            ($0.customStoragePath ?? root.appendingPathComponent($0.id.uuidString, isDirectory: true)).appendingPathComponent("workspace.json")
        })
        if resolution.provenance == .created {
            NotificationCenter.default.post(name: .workspaceDidCreate, object: nil, userInfo: ["workspaceID": resolution.workspace.id])
        }
        return resolution
    }

    private static func uniqueName(baseName: String, in candidates: [WorkspaceModel]) -> String {
        if !candidates.contains(where: { $0.name == baseName }) { return baseName }
        var counter = 1
        while candidates.contains(where: { $0.name == "\(baseName) (\(counter))" }) {
            counter += 1
        }
        return "\(baseName) (\(counter))"
    }
}
