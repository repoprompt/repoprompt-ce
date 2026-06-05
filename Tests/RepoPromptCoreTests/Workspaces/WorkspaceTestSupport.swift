import Foundation
@testable import RepoPromptCore

struct Slice1TestWorkspaceRootProvider: WorkspaceRepositoryRootProviding, Sendable {
    let root: URL

    func repositoryRoot() async -> URL {
        root
    }
}

struct Slice1TestWorkspaceGraph {
    let writer: WorkspacePersistenceWriter
    let repository: WorkspaceRepository

    init(
        root: URL,
        diagnostics: any WorkspaceRepositoryDiagnosticsSink = NoopWorkspaceRepositoryDiagnosticsSink()
    ) {
        let codec = EmbeddedWorkspaceCodecV1()
        let writer = WorkspacePersistenceWriter(codec: codec, diagnostics: diagnostics)
        self.writer = writer
        repository = WorkspaceRepository(
            rootProvider: Slice1TestWorkspaceRootProvider(root: root),
            codec: codec,
            writer: writer,
            diagnostics: diagnostics,
            migrationService: NoopWorkspaceLegacyMigrationService()
        )
    }
}

func makeSlice1TemporaryDirectory(
    named name: String,
    cleanup: @escaping (URL) -> Void
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    cleanup(url)
    return url
}

func makeSlice1Metadata(
    for workspace: WorkspaceModel,
    source: WorkspaceSaveSource = "test",
    selectionRevision: UInt64 = 0
) -> WorkspaceSavePayloadMetadata {
    let activeTab = workspace.activeComposeTabID.flatMap { id in
        workspace.composeTabs.first(where: { $0.id == id })
    }
    return WorkspaceSavePayloadMetadata(
        source: source,
        owner: .none,
        workspaceID: workspace.id,
        workspaceName: workspace.name,
        workspaceDateModified: workspace.dateModified,
        activeTabID: activeTab?.id,
        activeSelectionRevision: selectionRevision,
        activeSelection: activeTab?.selection
    )
}

func makeSlice1Workspace(
    id: UUID = UUID(),
    name: String = "Workspace",
    repoPaths: [String] = ["/tmp/root"],
    selection: StoredSelection = StoredSelection(),
    promptText: String = "",
    dateModified: Date = Date(timeIntervalSince1970: 100)
) -> WorkspaceModel {
    let tab = ComposeTabState(name: "T1", selection: selection, promptText: promptText)
    return WorkspaceModel(
        id: id,
        dateModified: dateModified,
        name: name,
        repoPaths: repoPaths,
        composeTabs: [tab],
        activeComposeTabID: tab.id
    )
}
