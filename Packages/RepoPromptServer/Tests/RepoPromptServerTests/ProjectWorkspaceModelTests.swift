import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ProjectWorkspaceModelTests: XCTestCase {
    func testPublicProjectAndRepositoryContractsArePathAndAliasFree() throws {
        let create = try JSONDecoder.serviceDecoder.decode(
            CreateProjectWireInput.self,
            from: Data(#"{"schemaVersion":1,"operationId":"11111111-1111-4111-8111-111111111111","expectedRevision":0,"name":"Workspace"}"#.utf8)
        )
        XCTAssertEqual(create.name, "Workspace")
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(
            CreateProjectWireInput.self,
            from: Data(#"{"schemaVersion":1,"operationId":"11111111-1111-4111-8111-111111111111","expectedRevision":0,"name":"Workspace","roots":[]}"#.utf8)
        ))

        let addition = try JSONDecoder.serviceDecoder.decode(
            AddProjectRepositoryInput.self,
            from: Data(#"{"schemaVersion":1,"expectedRevision":1,"logicalName":"server","source":{"type":"gitClone","remote":"https://github.com/repoprompt/repoprompt-ce.git","ref":"main"}}"#.utf8)
        )
        XCTAssertEqual(addition.logicalName, "server")
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(
            AddProjectRepositoryInput.self,
            from: Data(#"{"schemaVersion":1,"expectedRevision":1,"logicalName":"server","source":{"type":"configuredRoot","alias":"server"}}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(
            AddProjectRepositoryInput.self,
            from: Data(#"{"schemaVersion":1,"expectedRevision":1,"logicalName":"server","source":{"type":"gitClone","remote":"https://github.com/repoprompt/repoprompt-ce.git","ref":"main","token":"secret"}}"#.utf8)
        ))
    }

    func testEmptyProjectStartsSessionAndAddsMultipleManagedRepositoriesIdempotently() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-project-workspace-\(UUID().uuidString)", isDirectory: true)
        let cloneRoot = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let git = WorkspaceModelGitRunner()
        let service = try ProjectSourceProvisioningService(
            cloneRoot: cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(Self.policy()),
            credentials: try ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        let provider = WorkspaceModelProvider()
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider, projectSourceService: service)
        let actor = ExternalActor(userID: "workspace-owner", username: "owner", displayName: "Owner")
        let project = try await authority.createProject(
            input: .init(name: "  Empty Workspace  ", roots: []),
            externalActor: actor,
            idempotencyKey: "empty-project",
            requestDigest: "empty-project"
        )
        XCTAssertEqual(project.name, "Empty Workspace")
        XCTAssertTrue(project.roots.isEmpty)

        let session = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .codex,
                visibility: .privateSession,
                initialPrompt: "Set up this empty workspace",
                startImmediately: true
            ),
            externalActor: actor,
            idempotencyKey: "empty-session",
            requestDigest: "empty-session"
        )
        XCTAssertEqual(session.projectID, project.projectID)
        await authority.waitForProviderRunsToSettle()
        let workspace = try await service.projectWorkspaceDirectory(projectID: project.projectID)
        XCTAssertTrue(workspace.contains("/.project-workspaces/"))
        let providerWorkingDirectories = await provider.workingDirectories()
        XCTAssertEqual(providerWorkingDirectories, [workspace])

        let firstInput = AddProjectRepositoryInput(
            expectedRevision: 1,
            logicalName: "server",
            source: .init(remote: "https://github.com/repoprompt/repoprompt-ce.git", ref: "main")
        )
        let first = try await authority.addProjectRepository(
            projectID: project.projectID,
            input: firstInput,
            externalActor: actor,
            idempotencyKey: "add-server",
            requestDigest: "add-server"
        )
        let replay = try await authority.addProjectRepository(
            projectID: project.projectID,
            input: firstInput,
            externalActor: actor,
            idempotencyKey: "add-server",
            requestDigest: "add-server"
        )
        XCTAssertEqual(replay.operationID, first.operationID)

        let second = try await authority.addProjectRepository(
            projectID: project.projectID,
            input: .init(
                expectedRevision: 2,
                logicalName: "ops",
                source: .init(remote: "https://github.com/repoprompt/repoprompt-ce.git", ref: "main")
            ),
            externalActor: actor,
            idempotencyKey: "add-ops",
            requestDigest: "add-ops"
        )
        XCTAssertEqual(first.project?.revision, 2)
        XCTAssertEqual(second.project?.revision, 3)
        let snapshot = try await authority.projectSnapshot(projectID: project.projectID)
        XCTAssertEqual(snapshot.roots.count, 2)
        XCTAssertEqual(Set(snapshot.roots.map(\.logicalName)), ["server", "ops"])
        XCTAssertEqual(Set(snapshot.roots.map(\.canonicalPath)).count, 2)
        XCTAssertTrue(snapshot.roots.allSatisfy { $0.canonicalPath.hasPrefix(workspace + "/repositories/") })
        for root in snapshot.roots {
            let resource = try await store.ownedResource(externalID: root.rootID, kind: .cloneStaging)
            XCTAssertEqual(resource?.lifecycleState, .active)
        }

        let advertisedCapabilities = await authority.projectSourceCapabilities()
        let capabilities = try XCTUnwrap(advertisedCapabilities)
        let capabilityJSON = String(decoding: try JSONEncoder.serviceEncoder.encode(capabilities), as: UTF8.self)
        XCTAssertFalse(capabilityJSON.contains("configuredRoot"))
        XCTAssertFalse(capabilityJSON.contains("alias"))
        let cloneCount = await git.cloneCount()
        XCTAssertEqual(cloneCount, 2)
        try await store.close()
    }

    func testActiveProviderRunBlocksRepositoryPublication() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-project-workspace-\(UUID().uuidString)", isDirectory: true)
        let cloneRoot = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let git = WorkspaceModelGitRunner()
        let service = try ProjectSourceProvisioningService(
            cloneRoot: cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(Self.policy()),
            credentials: try ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        let provider = WorkspaceBlockingProvider()
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider, projectSourceService: service)
        let actor = ExternalActor(userID: "workspace-owner", username: "owner", displayName: "Owner")
        let project = try await authority.createProject(
            input: .init(name: "Workspace", roots: []),
            externalActor: actor,
            idempotencyKey: "blocked-project",
            requestDigest: "blocked-project"
        )
        _ = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .codex,
                visibility: .privateSession,
                initialPrompt: "Keep this run active",
                startImmediately: true
            ),
            externalActor: actor,
            idempotencyKey: "blocked-session",
            requestDigest: "blocked-session"
        )
        await provider.waitUntilStarted()
        do {
            _ = try await authority.addProjectRepository(
                projectID: project.projectID,
                input: .init(
                    expectedRevision: 1,
                    logicalName: "server",
                    source: .init(remote: "https://github.com/repoprompt/repoprompt-ce.git", ref: "main")
                ),
                externalActor: actor,
                idempotencyKey: "blocked-add",
                requestDigest: "blocked-add"
            )
            XCTFail("expected an active-run fence")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .runAlreadyActive)
        }
        let blockedCloneCount = await git.cloneCount()
        XCTAssertEqual(blockedCloneCount, 0)
        await provider.release()
        await authority.waitForProviderRunsToSettle()
        try await store.close()
    }

    func testDisabledGitPolicyStillStartsProviderInEmptyManagedWorkspace() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-project-workspace-\(UUID().uuidString)", isDirectory: true)
        let cloneRoot = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = try ProjectSourceProvisioningService(
            cloneRoot: cloneRoot.path,
            policy: .disabled,
            credentials: try ProjectSourceGitCredentials(),
            resources: store,
            git: WorkspaceModelGitRunner()
        )
        let provider = WorkspaceModelProvider()
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider, projectSourceService: service)
        let actor = ExternalActor(userID: "workspace-owner", username: "owner", displayName: "Owner")
        let project = try await authority.createProject(
            input: .init(name: "No Git Workspace", roots: []),
            externalActor: actor,
            idempotencyKey: "disabled-project",
            requestDigest: "disabled-project"
        )
        _ = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .codex,
                visibility: .privateSession,
                initialPrompt: "Work without a repository",
                startImmediately: true
            ),
            externalActor: actor,
            idempotencyKey: "disabled-session",
            requestDigest: "disabled-session"
        )
        await authority.waitForProviderRunsToSettle()
        let workspace = try await service.projectWorkspaceDirectory(projectID: project.projectID)
        let workingDirectories = await provider.workingDirectories()
        XCTAssertEqual(workingDirectories, [workspace])
        let advertisedCapabilities = await authority.projectSourceCapabilities()
        let capabilities = try XCTUnwrap(advertisedCapabilities)
        XCTAssertFalse(capabilities.gitCloneEnabled)
        try await store.close()
    }

    private static func policy() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "configuredRoots": [],
            "git": [
                "remoteRules": [["scheme": "https", "host": "github.com", "pathPrefix": "/repoprompt/"]],
                "allowedRefPatterns": ["^main$"],
                "deniedRefPatterns": [],
                "maximumCloneBytes": 8_388_608,
                "maximumCloneSeconds": 5,
                "maximumConcurrentClones": 1,
                "maximumOutputBytes": 16_384
            ]
        ])
    }
}

private actor WorkspaceModelProvider: AgentProviderDispatcher {
    private var directories: [String] = []

    func capabilities() -> [ProviderCapability] {
        [.init(kind: .codex, enabled: true, executable: "/usr/bin/true", supportsResume: false, supportsSteering: false)]
    }

    func preflight() -> [ProviderCapability] { capabilities() }
    func recoverProcessFamilies() throws {}
    func cancel(runID _: UUID) throws {}

    func execute(
        kind _: ProviderKind,
        model _: String?,
        prompt _: String,
        workingDirectory: String,
        maximumBytes _: Int,
        runID _: UUID?,
        resumeProviderSessionID _: String?,
        onProviderSessionIdentity _: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult {
        directories.append(workingDirectory)
        return ProviderExecutionResult(output: "Workspace ready", providerSessionID: nil)
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        try request.validateLaunch()
        try await request.acknowledgeLaunch()
        directories.append(request.workingDirectory)
        let result = ProviderExecutionResult(output: "Workspace ready", providerSessionID: nil)
        await onEvent(.assistantFinal(result.output))
        await onEvent(.completed(providerSessionID: nil))
        return result
    }

    func workingDirectories() -> [String] { directories }
}

private actor WorkspaceBlockingProvider: AgentProviderDispatcher {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func capabilities() -> [ProviderCapability] {
        [.init(kind: .codex, enabled: true, executable: "/usr/bin/true", supportsResume: false, supportsSteering: false)]
    }

    func preflight() -> [ProviderCapability] { capabilities() }
    func recoverProcessFamilies() throws {}
    func cancel(runID _: UUID) throws {}

    func execute(
        kind _: ProviderKind,
        model _: String?,
        prompt _: String,
        workingDirectory _: String,
        maximumBytes _: Int,
        runID _: UUID?,
        resumeProviderSessionID _: String?,
        onProviderSessionIdentity _: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return ProviderExecutionResult(output: "Done", providerSessionID: nil)
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        try request.validateLaunch()
        try await request.acknowledgeLaunch()
        let result = try await execute(
            kind: request.kind,
            model: request.model,
            prompt: request.prompt,
            workingDirectory: request.workingDirectory,
            maximumBytes: request.maximumBytes,
            runID: request.runID,
            resumeProviderSessionID: request.resumeProviderSessionID,
            onProviderSessionIdentity: { _ in }
        )
        await onEvent(.assistantFinal(result.output))
        await onEvent(.completed(providerSessionID: result.providerSessionID))
        return result
    }

    func waitUntilStarted() async {
        while !started { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor WorkspaceModelGitRunner: ProjectSourceGitRunning {
    private var clones = 0

    func cloneCount() -> Int { clones }

    func run(_ invocation: ProjectSourceGitInvocation) async throws -> String {
        if invocation.arguments.contains("clone") {
            clones += 1
            guard let destination = invocation.arguments.last else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Missing clone destination")
            }
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: destination).appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("ok".utf8).write(to: URL(fileURLWithPath: invocation.outputPath))
            return ""
        }
        if invocation.arguments.contains("--show-toplevel"),
           let index = invocation.arguments.firstIndex(of: "-C"), invocation.arguments.indices.contains(index + 1)
        {
            return invocation.arguments[index + 1]
        }
        if invocation.arguments.contains("get-url") {
            return "https://github.com/repoprompt/repoprompt-ce.git"
        }
        if invocation.arguments.contains("--verify") {
            return String(repeating: "a", count: 40)
        }
        return ""
    }
}
