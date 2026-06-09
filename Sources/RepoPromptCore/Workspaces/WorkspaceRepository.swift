import Foundation

package actor WorkspaceRepository: WorkspaceRepositoryContract {
    package typealias Document = WorkspaceModel

    private struct DecodeCacheKey: Hashable {
        let standardizedPath: String
        let fileSize: Int64
        let modificationDate: Date
    }

    private struct PendingIndexState {
        var entries: [WorkspaceIndexEntry]
        var mutation: UInt64
        var latestReceipt: WorkspaceWriteReceipt?
    }

    private let rootProvider: any WorkspaceRepositoryRootProviding
    private let codec: EmbeddedWorkspaceCodecV1
    private let writer: WorkspacePersistenceWriter
    private let diagnostics: any WorkspaceRepositoryDiagnosticsSink
    private let migrationService: any WorkspaceLegacyMigrationServicing
    private var decodeCache: [DecodeCacheKey: WorkspaceDocumentDecodeResult<WorkspaceModel>] = [:]
    private var pendingIndexStateByRoot: [URL: PendingIndexState] = [:]
    private var nextIndexMutation: UInt64 = 0

    package init(
        rootProvider: any WorkspaceRepositoryRootProviding,
        codec: EmbeddedWorkspaceCodecV1 = EmbeddedWorkspaceCodecV1(),
        writer: WorkspacePersistenceWriter,
        diagnostics: any WorkspaceRepositoryDiagnosticsSink = NoopWorkspaceRepositoryDiagnosticsSink(),
        migrationService: any WorkspaceLegacyMigrationServicing = NoopWorkspaceLegacyMigrationService()
    ) {
        self.rootProvider = rootProvider
        self.codec = codec
        self.writer = writer
        self.diagnostics = diagnostics
        self.migrationService = migrationService
    }

    package func currentRoot() async -> URL {
        await rootProvider.repositoryRoot()
    }

    package func currentLayout() async -> FixedWorkspaceRepositoryLayout {
        await FixedWorkspaceRepositoryLayout(repositoryRoot: currentRoot())
    }

    package func loadInventory(baseRoot: URL? = nil) async -> WorkspaceRepositoryInventory {
        let resolvedRoot = if let baseRoot { baseRoot } else { await currentRoot() }
        let layout = FixedWorkspaceRepositoryLayout(repositoryRoot: resolvedRoot)
        let rootKey = resolvedRoot.standardizedFileURL
        let entries: [WorkspaceIndexEntry]
        if let pending = pendingIndexStateByRoot[rootKey] {
            entries = pending.entries
        } else {
            guard FileManager.default.fileExists(atPath: layout.indexURL.path) else {
                return WorkspaceRepositoryInventory(entries: [], workspaces: [])
            }
            do {
                entries = try JSONDecoder().decode([WorkspaceIndexEntry].self, from: Data(contentsOf: layout.indexURL))
            } catch {
                diagnostics.record(.warning(code: "workspace_index_decode_failed", message: error.localizedDescription))
                return WorkspaceRepositoryInventory(entries: [], workspaces: [])
            }
        }

        var workspaces: [WorkspaceModel] = []
        var results: [UUID: WorkspaceDocumentDecodeResult<WorkspaceModel>] = [:]
        for entry in entries {
            let url = documentURL(for: entry, layout: layout)
            guard FileManager.default.fileExists(atPath: url.path) else {
                diagnostics.record(.warning(code: "workspace_document_missing", message: url.lastPathComponent))
                continue
            }
            do {
                let result = try loadWorkspace(at: url)
                workspaces.append(result.document)
                results[result.document.id] = result
                for warning in result.warnings {
                    diagnostics.record(.warning(code: warning.code, message: warning.message))
                }
            } catch {
                diagnostics.record(.warning(code: "workspace_document_decode_failed", message: error.localizedDescription))
            }
        }
        return WorkspaceRepositoryInventory(entries: entries, workspaces: workspaces, decodeResults: results)
    }

    package func loadWorkspaceSnapshotFromDisk(baseRoot: URL? = nil) async -> [WorkspaceModel] {
        await loadInventory(baseRoot: baseRoot).workspaces
    }

    package func list() async throws -> [WorkspaceModel] {
        await loadInventory().workspaces
    }

    package func load(id: UUID) async throws -> WorkspaceModel? {
        let inventory = await loadInventory()
        return inventory.workspaces.first(where: { $0.id == id })
    }

    package func loadWorkspace(at url: URL) throws -> WorkspaceDocumentDecodeResult<WorkspaceModel> {
        let key = try decodeCacheKey(for: url)
        if let cached = decodeCache[key] { return cached }
        let data = try Data(contentsOf: URL(fileURLWithPath: key.standardizedPath))
        let result = try codec.decode(data)
        if let keyAfterRead = try? decodeCacheKey(for: url), keyAfterRead == key {
            decodeCache[key] = result
        }
        return result
    }

    package func save(_ document: WorkspaceModel) async throws {
        let metadata = WorkspaceSavePayloadMetadata(
            source: "repository.save",
            owner: .none,
            workspaceID: document.id,
            workspaceName: document.name,
            workspaceDateModified: document.dateModified,
            activeTabID: document.activeComposeTabID,
            activeSelectionRevision: 0,
            activeSelection: activeSelection(in: document)
        )
        let receipt = try await saveWorkspace(document, metadata: metadata)
        let completion = await writer.flush(receipt)
        if let errorDescription = completion.errorDescription {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: errorDescription])
        }
        let indexReceipt = try await saveIndex([WorkspaceIndexEntry(workspace: document)], mergingExisting: true)
        try await flushIndex(indexReceipt, root: indexReceipt.url.deletingLastPathComponent())
    }

    @discardableResult
    package func saveWorkspace(
        _ workspace: WorkspaceModel,
        metadata: WorkspaceSavePayloadMetadata
    ) async throws -> WorkspaceWriteReceipt {
        let layout = await currentLayout()
        let directory = workspace.customStoragePath ?? layout.workspaceDirectory(id: workspace.id, name: workspace.name)
        try ensureWorkspaceDirectory(directory)
        let url = directory.appendingPathComponent("workspace.json")
        invalidate(url: url)
        return try await writer.enqueueWorkspace(workspace, url: url, metadata: metadata)
    }

    @discardableResult
    package func saveIndex(
        _ entries: [WorkspaceIndexEntry],
        mergingExisting: Bool = false,
        baseRoot: URL? = nil
    ) async throws -> WorkspaceWriteReceipt {
        let resolvedRoot = if let baseRoot { baseRoot } else { await currentRoot() }
        let layout = FixedWorkspaceRepositoryLayout(repositoryRoot: resolvedRoot)
        let rootKey = resolvedRoot.standardizedFileURL
        try FileManager.default.createDirectory(at: layout.repositoryRoot, withIntermediateDirectories: true)
        let finalEntries: [WorkspaceIndexEntry]
        if mergingExisting {
            var existing: [WorkspaceIndexEntry] = if let pending = pendingIndexStateByRoot[rootKey] {
                pending.entries
            } else if FileManager.default.fileExists(atPath: layout.indexURL.path),
                      let data = try? Data(contentsOf: layout.indexURL),
                      let decoded = try? JSONDecoder().decode([WorkspaceIndexEntry].self, from: data)
            {
                decoded
            } else {
                []
            }
            for entry in entries {
                if let index = existing.firstIndex(where: { $0.id == entry.id }) {
                    existing[index] = entry
                } else {
                    existing.append(entry)
                }
            }
            finalEntries = existing
        } else {
            finalEntries = entries
        }

        let data = try JSONEncoder().encode(finalEntries)
        nextIndexMutation &+= 1
        let mutation = nextIndexMutation
        pendingIndexStateByRoot[rootKey] = PendingIndexState(
            entries: finalEntries,
            mutation: mutation,
            latestReceipt: nil
        )
        let receipt = await writer.enqueue(data: data, url: layout.indexURL)
        if var pending = pendingIndexStateByRoot[rootKey], pending.mutation == mutation {
            pending.latestReceipt = receipt
            pendingIndexStateByRoot[rootKey] = pending
        }
        return receipt
    }

    package func flush(_ receipt: WorkspaceWriteReceipt) async -> WorkspaceWriteCompletion {
        let completion = await writer.flush(receipt)
        if completion.succeeded {
            let matchingRoot = pendingIndexStateByRoot.first { $0.value.latestReceipt == receipt }?.key
            if let matchingRoot { pendingIndexStateByRoot.removeValue(forKey: matchingRoot) }
        }
        return completion
    }

    package func flushWorkspace(_ workspace: WorkspaceModel) async -> WorkspaceWriteCompletion? {
        let url = await workspaceDocumentURL(for: workspace)
        return await writer.flush(url: url)
    }

    package func delete(id: UUID) async throws {
        let layout = await currentLayout()
        let inventory = await loadInventory(baseRoot: layout.repositoryRoot)
        guard let entry = inventory.entries.first(where: { $0.id == id }) else { return }
        if entry.customStoragePath == nil {
            let directory = layout.workspaceDirectory(id: entry.id, name: entry.name)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let remaining = inventory.entries.filter { $0.id != id }
        let receipt = try await saveIndex(remaining, baseRoot: layout.repositoryRoot)
        try await flushIndex(receipt, root: layout.repositoryRoot)
    }

    package func migrateLegacyHeadlessProfileIfNeeded() async throws -> WorkspaceLegacyMigrationResult {
        let root = await currentRoot()
        return try await migrationService.migrate(
            WorkspaceLegacyMigrationRequest(profileRoot: root, destinationRoot: root)
        )
    }

    package func workspaceDocumentURL(for workspace: WorkspaceModel, baseRoot: URL? = nil) async -> URL {
        let resolvedRoot = if let baseRoot { baseRoot } else { await currentRoot() }
        let layout = FixedWorkspaceRepositoryLayout(repositoryRoot: resolvedRoot)
        return workspace.customStoragePath?.appendingPathComponent("workspace.json") ??
            layout.workspaceDocumentURL(id: workspace.id, name: workspace.name)
    }

    package func workspaceDirectory(for workspace: WorkspaceModel, baseRoot: URL? = nil) async -> URL {
        let resolvedRoot = if let baseRoot { baseRoot } else { await currentRoot() }
        let layout = FixedWorkspaceRepositoryLayout(repositoryRoot: resolvedRoot)
        return workspace.customStoragePath ?? layout.workspaceDirectory(id: workspace.id, name: workspace.name)
    }

    package func invalidate(url: URL) {
        let path = url.standardizedFileURL.path
        decodeCache = decodeCache.filter { $0.key.standardizedPath != path }
    }

    #if DEBUG
        package func removeAllCachedDocumentsForTesting() {
            decodeCache.removeAll()
        }
    #endif

    private func flushIndex(_ receipt: WorkspaceWriteReceipt, root: URL) async throws {
        let completion = await flush(receipt)
        if let errorDescription = completion.errorDescription {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: errorDescription])
        }
        let rootKey = root.standardizedFileURL
        if pendingIndexStateByRoot[rootKey]?.latestReceipt == receipt {
            pendingIndexStateByRoot.removeValue(forKey: rootKey)
        }
    }

    private func documentURL(for entry: WorkspaceIndexEntry, layout: FixedWorkspaceRepositoryLayout) -> URL {
        entry.customStoragePath?.appendingPathComponent("workspace.json") ??
            layout.workspaceDocumentURL(id: entry.id, name: entry.name)
    }

    private func decodeCacheKey(for url: URL) throws -> DecodeCacheKey {
        let standardized = url.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = values.fileSize, let modificationDate = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown)
        }
        return DecodeCacheKey(
            standardizedPath: standardized.path,
            fileSize: Int64(fileSize),
            modificationDate: modificationDate
        )
    }

    private func ensureWorkspaceDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Chats", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func activeSelection(in workspace: WorkspaceModel) -> StoredSelection? {
        guard let activeID = workspace.activeComposeTabID else { return nil }
        return workspace.composeTabs.first(where: { $0.id == activeID })?.selection
    }
}
