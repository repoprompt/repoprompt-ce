import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServerOperations
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
private struct InjectedFilesystemFault: Error {}

final class WorkspaceAuthorityTests: XCTestCase {
    func testDurableFilesystemFaultBoundariesProduceOnlyOldOrCompleteState() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("complete durable payload".utf8)
        let preRename: [DurableFilesystemFaultPoint] = [.temporaryCreated, .contentsWritten, .temporarySynchronized]
        let postRename: [DurableFilesystemFaultPoint] = [.destinationRenamed, .directorySynchronized]

        for point in preRename + postRename {
            let temporary = root.appendingPathComponent("\(point.rawValue).tmp")
            let destination = root.appendingPathComponent("\(point.rawValue).json")
            let injector = DurableFilesystemFaultInjector { observed in
                if observed == point { throw InjectedFilesystemFault() }
            }
            XCTAssertThrowsError(try DurableFilesystem.publish(data: payload, temporary: temporary, destination: destination, faultInjector: injector))
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            if preRename.contains(point) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), point.rawValue)
            } else {
                XCTAssertEqual(try Data(contentsOf: destination), payload, point.rawValue)
            }
        }
    }

    func testProjectToolsAndSelectionAreAuthorizedAndDurable() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let database = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("\(UUID().uuidString).sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "alpha\nbeta needle\ngamma".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "struct Greeter {\n    func hello(name: String) -> String { name }\n}\n".write(to: root.appendingPathComponent("Greeter.swift"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        }

        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            codeMapBuilder: ServerWorkspaceCodeMapBuilder()
        )
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p", requestDigest: "p")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s", requestDigest: "s")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        XCTAssertEqual(
            project.roots.first?.canonicalPath,
            try LocalFilesystemAuthority().canonicalizeRoot(root.path).path
        )

        let tree = try await authority.projectTree(projectID: project.projectID, request: .init(rootID: rootID))
        XCTAssertEqual(tree.map(\.logicalPath), ["Greeter.swift", "notes.txt"])
        let hits = try await authority.projectSearch(projectID: project.projectID, request: .init(rootID: rootID, query: "needle"))
        XCTAssertEqual(hits.first?.line, 2)
        let file = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "notes.txt", startLine: 2, lineCount: 1))
        XCTAssertEqual(file.content, "beta needle")
        let codeMap = try await authority.projectCodeMap(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "Greeter.swift"))
        XCTAssertEqual(codeMap.status, "ready")
        XCTAssertEqual(codeMap.language, "swift")
        XCTAssertTrue(codeMap.content.contains("Greeter"))
        XCTAssertTrue(codeMap.content.contains("hello"))

        let entry = LogicalSelectionEntry(rootID: rootID, logicalPath: "notes.txt", mode: .full)
        let selected = try await authority.replaceSelection(sessionID: session.sessionID, entries: [entry], expectedRevision: 1, actor: actor)
        XCTAssertEqual(selected.revision, 2)
        do {
            _ = try await authority.replaceSelection(sessionID: session.sessionID, entries: [], expectedRevision: 1, actor: actor)
            XCTFail("expected stale selection revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        try await store.close()

        let reopened = try await SQLiteServiceStore.open(storage: .file(database.path))
        let recovered = RepoPromptHeadlessAuthority(store: reopened)
        try await recovered.recover()
        let recoveredSelection = try await recovered.selectionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(recoveredSelection, selected)
        try await reopened.close()
    }

    func testSymlinkEscapeIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p", requestDigest: "p")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        do {
            _ = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "escape/secret.txt"))
            XCTFail("expected root escape rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        try await store.close()
    }

    func testAuthorizedRootIdentityReplacementIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-root-identity", requestDigest: "p-root-identity")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        try "later".write(to: root.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        _ = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "later.txt"))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "replacement".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "value.txt"))
            XCTFail("expected root identity rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        try await store.close()
    }

    func testAuthorizedRootIdentityPersistsAcrossAuthorityRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let database = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("\(UUID().uuidString).sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        }
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let initialStore = try await SQLiteServiceStore.open(storage: .file(database.path))
        let initialAuthority = RepoPromptHeadlessAuthority(store: initialStore)
        let project = try await initialAuthority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "persisted-root", requestDigest: "persisted-root")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        try await initialStore.close()

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "replacement".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)

        let recoveredStore = try await SQLiteServiceStore.open(storage: .file(database.path))
        let recoveredAuthority = RepoPromptHeadlessAuthority(store: recoveredStore)
        try await recoveredAuthority.recover()
        do {
            _ = try await recoveredAuthority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "value.txt"))
            XCTFail("expected persisted root identity rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        try await recoveredStore.close()
    }

    func testWorktreeServiceUsesValidatedGitArguments() async throws {
        let runner = RecordingWorkspaceRunner()
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = try WorktreeRuntimeService(baseDirectory: base.path, runner: runner)
        let root = ProjectRootSnapshot(rootID: UUID(), logicalName: "source", canonicalPath: "/repo", writable: true)
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: .init(userID: "u", username: "u", displayName: "U"), state: .active, roots: [root], revision: 1, cursor: .init(storeID: UUID(), globalSequence: 1))
        let binding = try await service.create(project: project, root: root, sessionID: UUID(), baseRef: "main", branch: "rp/session")
        XCTAssertEqual(binding.ownershipState, .active)
        let calls = await runner.calls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.arguments.prefix(5), ["-C", "/repo", "worktree", "add", "-b"])
        do {
            _ = try await service.create(project: project, root: root, sessionID: UUID(), baseRef: "--help", branch: "bad")
            XCTFail("expected invalid ref")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
    }

    func testProjectTemplateSeedsRootSessionAndChildInheritsFrozenSelection() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "template".write(to: root.appendingPathComponent("template.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-template", requestDigest: "p-template")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let entry = LogicalSelectionEntry(rootID: rootID, logicalPath: "template.txt", mode: .full)
        let template = try await authority.replaceProjectSelectionTemplate(projectID: project.projectID, entries: [entry], expectedRevision: 1, actor: actor, idempotencyKey: "template", requestDigest: "template")
        XCTAssertEqual(template.revision, 2)

        let parent = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "parent", requestDigest: "parent")
        let parentSelection = try await authority.selectionSnapshot(sessionID: parent.sessionID)
        XCTAssertEqual(parentSelection.entries, [entry])
        let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, initialPrompt: "child")
        let childSelection = try await authority.selectionSnapshot(sessionID: child.sessionID)
        XCTAssertEqual(childSelection.entries, [entry])
        XCTAssertEqual(child.rootSessionID, parent.sessionID)
        do {
            _ = try await authority.createSession(input: .init(projectID: project.projectID, parentSessionID: parent.sessionID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "external-child", requestDigest: "external-child")
            XCTFail("expected public child-session rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }
        try await store.close()
    }

    func testContextBuilderOracleAndContextArtifactsUseConfiguredProvider() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-context-builder-root-\(UUID().uuidString)")
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-context-builder-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "important context".write(to: root.appendingPathComponent("important.txt"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = WorkflowWorkspaceRunner()
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let artifactService = try ArtifactRuntimeService(baseDirectory: artifacts.path)
        let settings = try await configuredAgentSettings(store: store, adapter: provider, runner: runner)
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            artifactService: artifactService,
            providerAdapter: provider,
            serverSettings: settings.server,
            providerSettings: settings.provider
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p", requestDigest: "p")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s", requestDigest: "s")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        await runner.setContextBuilderResponse("{\"tool\":\"manage_selection\",\"args\":{\"op\":\"set\",\"entries\":[{\"rootID\":\"\(rootID.uuidString)\",\"path\":\"important.txt\"}]}}")

        let selection = try await authority.runContextBuilder(sessionID: session.sessionID, input: .init(expectedSelectionRevision: 1, instructions: "find important context", budget: 10000), actor: actor)
        XCTAssertEqual(selection.entries.map(\.logicalPath), ["important.txt"])
        XCTAssertEqual(selection.response, "builder plan")
        XCTAssertNotNil(selection.chatID)
        let builderContext = try await authority.sessionContext(sessionID: session.sessionID)
        XCTAssertEqual(builderContext.prompt, "Use the selected important context.")
        let context = try await authority.buildContext(sessionID: session.sessionID, expectedSelectionRevision: selection.revision, include: ["files"], actor: actor)
        let contextData = try await authority.artifactContent(artifactID: context.artifactID, maximumBytes: 1_048_576)
        XCTAssertTrue(String(decoding: contextData, as: UTF8.self).contains("important context"))

        let oracle = try await authority.askOracle(sessionID: session.sessionID, input: .init(chatID: selection.chatID, prompt: "explain", contextMode: "selected"), actor: actor)
        XCTAssertEqual(oracle.response, "oracle response")
        XCTAssertNotNil(oracle.artifactID)
        XCTAssertEqual(oracle.revision, 2)
        let continuedOracle = try await authority.askOracle(sessionID: session.sessionID, input: .init(chatID: oracle.chatID, prompt: "continue", contextMode: "selected"), actor: actor)
        XCTAssertEqual(continuedOracle.chatID, oracle.chatID)
        XCTAssertEqual(continuedOracle.revision, 3)
        let oraclePrompts = await runner.oraclePrompts()
        XCTAssertTrue(oraclePrompts.last?.contains("<user>explain</user>") == true)
        let enabledProviders = await authority.providerCapabilities().filter(\.enabled).map(\.kind)
        XCTAssertEqual(enabledProviders, [.codex])
        try await store.close()
    }

    func testContextBuilderStaleCommitRetainsInspectableProposalArtifact() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-context-builder-root-\(UUID().uuidString)")
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-context-builder-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "context".write(to: root.appendingPathComponent("Context.swift"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = BlockingContextBuilderRuntime()
        let settingsRunner = WorkflowWorkspaceRunner()
        let settingsAdapter = ProviderCLIAdapter(
            configurations: [.init(kind: .codex, executable: "/usr/bin/true")],
            runner: settingsRunner
        )
        let settings = try await configuredAgentSettings(
            store: store,
            adapter: settingsAdapter,
            runner: settingsRunner
        )
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path),
            contextBuilderRuntime: runtime,
            serverSettings: settings.server,
            providerSettings: settings.provider
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-cb-race", requestDigest: "p-cb-race")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-cb-race", requestDigest: "s-cb-race")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        await runtime.setProposal(.init(selection: [.init(rootID: rootID, logicalPath: "Context.swift", mode: .full)], response: "proposal", providerSessionID: "builder", rawProviderOutput: "fixture"))

        let builder = Task {
            try await authority.runContextBuilder(sessionID: session.sessionID, input: .init(expectedSelectionRevision: 1, instructions: "select", budget: 10000), actor: actor)
        }
        for _ in 0 ..< 100 {
            if await runtime.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let didStart = await runtime.hasStarted()
        XCTAssertTrue(didStart)
        _ = try await authority.replaceSelection(sessionID: session.sessionID, entries: [], expectedRevision: 1, actor: actor)
        await runtime.release()
        do {
            _ = try await builder.value
            XCTFail("expected stale selection commit")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, 2)
        }
        let retained = try await store.artifacts(sessionID: session.sessionID)
        XCTAssertEqual(retained.map(\.snapshot.kind), ["context-builder-proposal"])
        let data = try await authority.artifactContent(artifactID: XCTUnwrap(retained.first?.snapshot.artifactID), maximumBytes: 1_048_576)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Context.swift"))
        try await store.close()
    }

    func testContextBuilderClarifyingQuestionUsesDurableAuthorityInteraction() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-context-builder-root-\(UUID().uuidString)")
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-context-builder-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = QuestionWorkspaceRunner()
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let settings = try await configuredAgentSettings(store: store, adapter: provider, runner: runner)
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path),
            providerAdapter: provider,
            serverSettings: settings.server,
            providerSettings: settings.provider
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-question", requestDigest: "p-question")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-question", requestDigest: "s-question")

        let builder = Task {
            try await authority.runContextBuilder(
                sessionID: session.sessionID,
                input: .init(expectedSelectionRevision: 1, instructions: "clarify", budget: 10000, allowClarifyingQuestions: true),
                actor: actor
            )
        }
        var pending: InteractionSnapshot?
        for _ in 0 ..< 100 {
            pending = try await authority.interactionSnapshots(sessionID: session.sessionID).first(where: { $0.state == .pending })
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if pending == nil {
            do {
                _ = try await builder.value
                XCTFail("Context Builder completed without requesting the expected interaction")
            } catch {
                XCTFail("Context Builder failed before requesting the expected interaction: \(error)")
            }
        }
        let interaction = try XCTUnwrap(pending)
        XCTAssertEqual(interaction.kind, .question)
        _ = try await authority.answerInteraction(
            sessionID: session.sessionID,
            interactionID: interaction.interactionID,
            expectedRevision: interaction.revision,
            payload: Data(#"{"answer":"Use the service target"}"#.utf8),
            actor: actor
        )
        let result = try await builder.value
        XCTAssertEqual(result.revision, 2)
        let receivedAnswer = await runner.receivedAnswer
        XCTAssertTrue(receivedAnswer)
        try await store.close()
    }

    func testReadOnlyRootReplacementIsRejectedBeforeProviderRouting() async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-read-only-routing-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let displacedSource = base.appendingPathComponent("source-original", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        let artifacts = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "trusted".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "outside".write(to: outside.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = MultiRootWorkspaceProvider()
        let worktreeService = try WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store)
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktreeService,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store),
            providerAdapter: provider
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "Read only", roots: [.init(logicalName: "docs", path: source.path, writable: false)]),
            externalActor: actor,
            idempotencyKey: "read-only-project",
            requestDigest: "read-only-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "inspect", startImmediately: false),
            externalActor: actor,
            idempotencyKey: "read-only-session",
            requestDigest: "read-only-session"
        )
        try FileManager.default.moveItem(at: source, to: displacedSource)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        do {
            _ = try await authority.execute(
                command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                sessionID: session.sessionID,
                externalActor: actor,
                idempotencyKey: "read-only-resume",
                requestDigest: "read-only-resume"
            )
            XCTFail("expected read-only root identity rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        let routedRequests = await provider.requests()
        let persistedRun = try await store.latestRun(sessionID: session.sessionID)
        XCTAssertTrue(routedRequests.isEmpty)
        XCTAssertNil(persistedRun)
        try await worktreeService.removeOrphanedExecutionWorkspaces(validOwnerSessionIDs: [])
        try await store.close()
        try FileManager.default.removeItem(at: base)
    }

    func testReadOnlyRootSwapAfterRunPersistenceIsRejectedAtProviderLaunchBoundary() async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-launch-boundary-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let displacedSource = base.appendingPathComponent("source-original", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        let artifacts = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "trusted".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = LaunchBoundaryWorkspaceProvider()
        let worktreeService = try WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store)
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktreeService,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store),
            providerAdapter: provider
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "Launch boundary", roots: [.init(logicalName: "docs", path: source.path, writable: false)]),
            externalActor: actor,
            idempotencyKey: "launch-boundary-project",
            requestDigest: "launch-boundary-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "inspect", startImmediately: false),
            externalActor: actor,
            idempotencyKey: "launch-boundary-session",
            requestDigest: "launch-boundary-session"
        )
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: actor,
            idempotencyKey: "launch-boundary-resume",
            requestDigest: "launch-boundary-resume"
        )
        for _ in 0 ..< 200 {
            if await provider.hasReceivedRequest() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let receivedAtLaunchBoundary = await provider.hasReceivedRequest()
        XCTAssertTrue(receivedAtLaunchBoundary)
        try FileManager.default.moveItem(at: source, to: displacedSource)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        await provider.releaseLaunch()
        await authority.waitForProviderRunsToSettle()
        let providerLaunched = await provider.didLaunch()
        let failedRun = try await store.latestRun(sessionID: session.sessionID)
        XCTAssertFalse(providerLaunched)
        XCTAssertEqual(failedRun?.state, "failed")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: displacedSource, to: source)
        try await worktreeService.removeOrphanedExecutionWorkspaces(validOwnerSessionIDs: [])
        try await store.close()
        try FileManager.default.removeItem(at: base)
    }

    func testExecutionWorkspaceBaseAndAncestorSwapsCannotStageOrDeleteOutsidePinnedRoot() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-workspace-swap-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let displacedParent = root.appendingPathComponent("parent-original", isDirectory: true)
        let base = parent.appendingPathComponent("worktrees", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideWorktrees = outside.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideWorktrees, withIntermediateDirectories: true)

        let service = try WorktreeRuntimeService(baseDirectory: base.path)
        let project = ProjectSnapshot(
            projectID: UUID(),
            name: "Empty",
            creator: .init(userID: "u", username: "u", displayName: "U"),
            state: .active,
            roots: [],
            revision: 1,
            cursor: .init(storeID: UUID(), globalSequence: 1)
        )
        let ownerSessionID = UUID()
        try FileManager.default.moveItem(at: parent, to: displacedParent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        do {
            _ = try await service.materializeExecutionWorkspace(
                project: project,
                ownerSessionID: ownerSessionID,
                bindings: [],
                readOnlyRootIdentities: [:]
            )
            XCTFail("expected execution workspace ancestor rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideWorktrees.appendingPathComponent(".execution-workspaces").path))

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: displacedParent, to: parent)
        let workspace = try await service.materializeExecutionWorkspace(
            project: project,
            ownerSessionID: ownerSessionID,
            bindings: [],
            readOnlyRootIdentities: [:]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.directory))

        let displacedBase = parent.appendingPathComponent("worktrees-original", isDirectory: true)
        let outsideBase = root.appendingPathComponent("outside-base", isDirectory: true)
        try FileManager.default.moveItem(at: base, to: displacedBase)
        try FileManager.default.createDirectory(at: outsideBase, withIntermediateDirectories: true)
        let outsideSentinel = outsideBase.appendingPathComponent("sentinel")
        try "keep".write(to: outsideSentinel, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: outsideBase)
        do {
            try await service.removeExecutionWorkspace(projectID: project.projectID, ownerSessionID: ownerSessionID)
            XCTFail("expected execution workspace base rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        XCTAssertEqual(try String(contentsOf: outsideSentinel, encoding: .utf8), "keep")
        let pinnedWorkspace = displacedBase
            .appendingPathComponent(".execution-workspaces", isDirectory: true)
            .appendingPathComponent(project.projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(ownerSessionID.uuidString.lowercased(), isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedWorkspace.path))
        try FileManager.default.removeItem(at: base)
        try FileManager.default.moveItem(at: displacedBase, to: base)
        let restoredWorkspace = base
            .appendingPathComponent(".execution-workspaces", isDirectory: true)
            .appendingPathComponent(project.projectID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(ownerSessionID.uuidString.lowercased(), isDirectory: true)
        let displacedWorkspace = restoredWorkspace.deletingLastPathComponent()
            .appendingPathComponent("\(ownerSessionID.uuidString.lowercased())-original", isDirectory: true)
        try FileManager.default.moveItem(at: restoredWorkspace, to: displacedWorkspace)
        try FileManager.default.createSymbolicLink(at: restoredWorkspace, withDestinationURL: outsideBase)
        do {
            try await service.removeExecutionWorkspace(projectID: project.projectID, ownerSessionID: ownerSessionID)
            XCTFail("expected execution workspace entry rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        XCTAssertEqual(try String(contentsOf: outsideSentinel, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: restoredWorkspace)
        try FileManager.default.moveItem(at: displacedWorkspace, to: restoredWorkspace)
        try await service.removeExecutionWorkspace(projectID: project.projectID, ownerSessionID: ownerSessionID)
        try FileManager.default.removeItem(at: root)
    }

    func testMergeRejectsWhileChildProviderRunIsActiveAndPreservesBinding() async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-child-merge-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        let artifacts = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let command = LocalWorkspaceCommandRunner()
        try "source".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["init", "-b", "main", source.path], workingDirectory: base.path, maximumBytes: 65536)
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", source.path, "add", "README.md"], workingDirectory: source.path, maximumBytes: 65536)
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", source.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"], workingDirectory: source.path, maximumBytes: 65536)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = BlockingWorkspaceProvider()
        let worktreeService = try WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store)
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktreeService,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store),
            providerAdapter: provider
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "Merge fence", roots: [.init(logicalName: "source", path: source.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "merge-fence-project",
            requestDigest: "merge-fence-project"
        )
        let rootSession = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "root", startImmediately: false),
            externalActor: actor,
            idempotencyKey: "merge-fence-root",
            requestDigest: "merge-fence-root"
        )
        let child = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "child run")
        _ = try await authority.startChildAgentRun(sessionID: child.sessionID)
        for _ in 0 ..< 200 {
            if await provider.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let childRunStarted = await provider.hasStarted()
        XCTAssertTrue(childRunStarted)
        let projectBindings = try await authority.worktreeSnapshots(projectID: project.projectID)
        let binding = try XCTUnwrap(projectBindings.first { $0.sessionID == rootSession.sessionID })
        do {
            _ = try await authority.mergeWorktree(
                sessionID: rootSession.sessionID,
                bindingID: binding.bindingID,
                strategy: "merge",
                expectedRevision: binding.revision,
                actor: actor,
                idempotencyKey: "merge-fence-attempt",
                requestDigest: "merge-fence-attempt"
            )
            XCTFail("expected active child run to fence merge")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .runAlreadyActive)
        }
        let preservedBinding = try await store.worktree(bindingID: binding.bindingID)
        let mergeLeases = try await store.worktreeMergeLeases(nonterminalOnly: false)
        let childStillRunning = await provider.hasStarted()
        XCTAssertEqual(preservedBinding, binding)
        XCTAssertTrue(mergeLeases.isEmpty)
        XCTAssertTrue(childStillRunning)
        _ = try await authority.cancelChildAgentRun(sessionID: child.sessionID)
        await authority.waitForProviderRunsToSettle()
        try await worktreeService.removeOrphanedExecutionWorkspaces(validOwnerSessionIDs: [])
        try await store.close()
        try FileManager.default.removeItem(at: base)
    }

    func testProjectExecutionWorkspaceRoutesEveryWritableRepositoryAcrossRestartAndResume() async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-multi-root-\(UUID().uuidString)", isDirectory: true)
        let sourceA = base.appendingPathComponent("source-a", isDirectory: true)
        let sourceB = base.appendingPathComponent("source-b", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        let artifacts = base.appendingPathComponent("artifacts", isDirectory: true)
        let database = base.appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let command = LocalWorkspaceCommandRunner()
        for (root, content) in [(sourceA, "source checkout A"), (sourceB, "source checkout B")] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try content.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try await command.run(executable: "/usr/bin/git", arguments: ["init", "-b", "main", root.path], workingDirectory: base.path, maximumBytes: 65536)
            _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", root.path, "add", "README.md"], workingDirectory: root.path, maximumBytes: 65536)
            _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", root.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"], workingDirectory: root.path, maximumBytes: 65536)
        }

        let provider = MultiRootWorkspaceProvider()
        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        var worktreeService = try WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store)
        var authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktreeService,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store),
            providerAdapter: provider
        )
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "P", roots: [
                .init(logicalName: "server", path: sourceA.path, writable: true),
                .init(logicalName: "ops", path: sourceB.path, writable: true)
            ]),
            externalActor: actor,
            idempotencyKey: "p-multi-wt",
            requestDigest: "p-multi-wt"
        )
        XCTAssertEqual(project.roots.count, 2)
        _ = try await authority.replaceProjectSelectionTemplate(
            projectID: project.projectID,
            entries: project.roots.map { .init(rootID: $0.rootID, logicalPath: "README.md", mode: .full) },
            expectedRevision: 1,
            actor: actor,
            idempotencyKey: "template-multi-wt",
            requestDigest: "template-multi-wt"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "modify both roots", startImmediately: true),
            externalActor: actor,
            idempotencyKey: "s-multi-wt",
            requestDigest: "s-multi-wt"
        )
        await authority.waitForProviderRunsToSettle()

        let bindings = try await authority.worktreeSnapshots(projectID: project.projectID).filter { $0.sessionID == session.sessionID && $0.ownershipState == .active }
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(Set(bindings.map(\.rootID)), Set(project.roots.map(\.rootID)))
        XCTAssertEqual(Set(bindings.map(\.physicalPath)).count, 2)
        XCTAssertTrue(bindings.allSatisfy { $0.physicalPath.hasPrefix(worktrees.path) })
        let initialRequests = await provider.requests()
        let firstRequest = try XCTUnwrap(initialRequests.first)
        XCTAssertTrue(firstRequest.workingDirectory.contains("/.execution-workspaces/"))
        XCTAssertNotEqual(firstRequest.workingDirectory, bindings[0].physicalPath)
        XCTAssertNotEqual(firstRequest.workingDirectory, bindings[1].physicalPath)
        let expectedWritableRoots = try project.roots.map { root in
            try XCTUnwrap(bindings.first(where: { $0.rootID == root.rootID })?.physicalPath)
        }
        XCTAssertEqual(firstRequest.writableRoots, expectedWritableRoots)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: firstRequest.workingDirectory).appendingPathComponent("workspace.json").path))
        let initialWorkspaceIdentity = try FileManager.default.attributesOfItem(atPath: firstRequest.workingDirectory)[.systemFileNumber] as? NSNumber
        for root in project.roots {
            let binding = try XCTUnwrap(bindings.first(where: { $0.rootID == root.rootID }))
            let route = URL(fileURLWithPath: firstRequest.workingDirectory).appendingPathComponent("roots/\(root.rootID.uuidString.lowercased())")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: route.path), binding.physicalPath)
            let isolated = try String(contentsOf: URL(fileURLWithPath: binding.physicalPath).appendingPathComponent("README.md"), encoding: .utf8)
            XCTAssertTrue(isolated.contains(root.rootID.uuidString.lowercased()))
        }
        XCTAssertEqual(try String(contentsOf: sourceA.appendingPathComponent("README.md"), encoding: .utf8), "source checkout A")
        XCTAssertEqual(try String(contentsOf: sourceB.appendingPathComponent("README.md"), encoding: .utf8), "source checkout B")

        let rootArtifact = try await authority.buildContext(sessionID: session.sessionID, expectedSelectionRevision: 1, include: ["files"], actor: actor)
        let child = try await authority.spawnChildSession(parentSessionID: session.sessionID, initialPrompt: "inspect both")
        let childArtifact = try await authority.buildContext(sessionID: child.sessionID, expectedSelectionRevision: 1, include: ["files"], actor: actor)
        let rootContent = String(decoding: try await authority.artifactContent(artifactID: rootArtifact.artifactID, maximumBytes: 4096), as: UTF8.self)
        let childContent = String(decoding: try await authority.artifactContent(artifactID: childArtifact.artifactID, maximumBytes: 4096), as: UTF8.self)
        for root in project.roots {
            XCTAssertTrue(rootContent.contains(root.rootID.uuidString.lowercased()))
            XCTAssertTrue(childContent.contains(root.rootID.uuidString.lowercased()))
        }
        let childAuthoritySnapshot = try await authority.authoritySessionSnapshot(sessionID: child.sessionID)
        XCTAssertEqual(childAuthoritySnapshot.worktrees.count, 2)
        let reusedWorkspaceIdentity = try FileManager.default.attributesOfItem(atPath: firstRequest.workingDirectory)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(reusedWorkspaceIdentity, initialWorkspaceIdentity)

        let currentResources = try await store.ownedResources(states: [.active])
        let currentWorktreeResources = currentResources.filter { $0.kind == .worktree && bindings.map(\.bindingID).contains($0.externalID) }
        XCTAssertEqual(currentWorktreeResources.count, 2)
        XCTAssertTrue(currentWorktreeResources.allSatisfy { $0.contentDigest != nil })
        try await store.close()
        _ = try await command.run(
            executable: "/usr/bin/sqlite3",
            arguments: [database.path, "UPDATE owned_resources SET content_digest=NULL WHERE kind='worktree' AND lifecycle_state='active'"],
            workingDirectory: base.path,
            maximumBytes: 65536
        )
        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let legacyResources = try await store.ownedResources(states: [.active]).filter { $0.kind == .worktree }
        XCTAssertEqual(legacyResources.count, 2)
        XCTAssertTrue(legacyResources.allSatisfy { $0.contentDigest == nil })
        let reconciler = try OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: artifacts.path,
            worktreeRoot: worktrees.path,
            runner: command
        )
        let reconciliation = try await reconciler.reconcileStartup()
        XCTAssertEqual(reconciliation.failed, 0)
        XCTAssertEqual(reconciliation.quarantined, 0)
        let backfilledResources = try await store.ownedResources(states: [.active]).filter { $0.kind == .worktree }
        XCTAssertEqual(backfilledResources.count, 2)
        XCTAssertTrue(backfilledResources.allSatisfy { $0.contentDigest != nil })
        worktreeService = try WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store)
        authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktreeService,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store),
            providerAdapter: provider
        )
        try await authority.recover()
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: actor,
            idempotencyKey: "resume-multi-wt",
            requestDigest: "resume-multi-wt"
        )
        await authority.waitForProviderRunsToSettle()
        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].workingDirectory, requests[0].workingDirectory)
        XCTAssertEqual(requests[1].writableRoots, expectedWritableRoots)
        let recoveredBindings = try await authority.authoritySessionSnapshot(sessionID: session.sessionID).worktrees
        XCTAssertEqual(Set(recoveredBindings.map(\.bindingID)), Set(bindings.map(\.bindingID)))
        let resources = try await store.ownedResources(states: [.active])
        let recoveredResources = resources.filter { $0.kind == .worktree && bindings.map(\.bindingID).contains($0.externalID) }
        XCTAssertEqual(recoveredResources.count, 2)
        XCTAssertEqual(Set(recoveredResources.compactMap(\.contentDigest)), Set(backfilledResources.compactMap(\.contentDigest)))
        _ = try await reconciler.reconcileStartup()
        let repeatedResources = try await store.ownedResources(states: [.active]).filter { $0.kind == .worktree }
        XCTAssertEqual(Set(repeatedResources.compactMap(\.contentDigest)), Set(backfilledResources.compactMap(\.contentDigest)))
        try await worktreeService.removeOrphanedExecutionWorkspaces(validOwnerSessionIDs: [])
        try await store.close()
        try FileManager.default.removeItem(at: base)
    }

    private func configuredAgentSettings(
        store: SQLiteServiceStore,
        adapter: any ProviderRuntimeSettingsAdapting,
        runner: any WorkspaceCommandRunning
    ) async throws -> (provider: ProviderSettingsService, server: ServerSettingsService) {
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoprompt-server-test-models-\(UUID().uuidString).json")
        try JSONEncoder.serviceEncoder.encode([
            ProviderModelCatalogEntry(
                id: "gpt-5.6-sol",
                displayName: "GPT-5.6 Sol",
                isProviderDefault: true
            ),
        ]).write(to: modelCatalogURL)
        defer { try? FileManager.default.removeItem(at: modelCatalogURL) }
        let configuration = ProviderCLIConfiguration(
            kind: .codex,
            executable: "/usr/bin/true",
            expectedVersion: "1.0",
            credentialSourceDirectory: FileManager.default.temporaryDirectory.path
        )
        let provider = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [configuration],
            initiallyEnabled: [.codex],
            modelCatalogFiles: [.codex: modelCatalogURL.path],
            runner: runner
        )
        try await provider.bootstrap()
        _ = try await provider.setEnabled(
            providerID: .codex,
            enabled: true,
            request: .init(expectedRevision: 1),
            attribution: .init(actorID: "test", actorLabel: "Test", channel: "test")
        )
        let server = ServerSettingsService(
            store: store,
            providerCatalog: provider,
            projectCatalog: store
        )
        let target = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol")
        _ = try await server.replaceGlobalAgentModels(
            .init(expectedRevision: 0, profile: .init(oracle: target, contextBuilder: target)),
            attribution: .init(actorID: "test", actorLabel: "Test", channel: "test")
        )
        return (provider, server)
    }
}

private actor LaunchBoundaryWorkspaceProvider: AgentProviderDispatcher {
    private var receivedRequest = false
    private var launched = false
    private var launchContinuation: CheckedContinuation<Void, Never>?

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
        ProviderExecutionResult(output: "unused", providerSessionID: nil)
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent _: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        receivedRequest = true
        await withCheckedContinuation { launchContinuation = $0 }
        try request.validateLaunch()
        try await request.acknowledgeLaunch()
        launched = true
        return ProviderExecutionResult(output: "launched", providerSessionID: nil)
    }

    func hasReceivedRequest() -> Bool { receivedRequest }
    func didLaunch() -> Bool { launched }

    func releaseLaunch() {
        launchContinuation?.resume()
        launchContinuation = nil
    }
}

private actor BlockingWorkspaceProvider: AgentProviderDispatcher {
    private var started = false

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
        ProviderExecutionResult(output: "unused", providerSessionID: nil)
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent _: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        try request.validateLaunch()
        try await request.acknowledgeLaunch()
        started = true
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    func hasStarted() -> Bool { started }
}

private actor MultiRootWorkspaceProvider: AgentProviderDispatcher {
    struct CapturedRequest: Sendable {
        let workingDirectory: String
        let writableRoots: [String]
    }

    private var captured: [CapturedRequest] = []

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
        ProviderExecutionResult(output: "unused", providerSessionID: nil)
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        try request.validateLaunch()
        try await request.acknowledgeLaunch()
        captured.append(.init(workingDirectory: request.workingDirectory, writableRoots: request.policy.writableRoots))
        let routes = URL(fileURLWithPath: request.workingDirectory).appendingPathComponent("roots", isDirectory: true)
        let roots = try FileManager.default.contentsOfDirectory(at: routes, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard roots.count == 2 else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Provider did not receive the complete project workspace")
        }
        for root in roots {
            try "isolated \(root.lastPathComponent)".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
        await onEvent(.completed(providerSessionID: nil))
        return ProviderExecutionResult(output: "modified both roots", providerSessionID: nil)
    }

    func requests() -> [CapturedRequest] { captured }
}

private actor RecordingWorkspaceRunner: WorkspaceCommandRunning {
    struct Call {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
    }

    private var recorded: [Call] = []

    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes _: Int) async throws -> String {
        recorded.append(Call(executable: executable, arguments: arguments, workingDirectory: workingDirectory))
        if arguments.suffix(2) == ["rev-parse", "--show-toplevel"], arguments.count >= 2 {
            return arguments[1]
        }
        return ""
    }

    func calls() -> [Call] {
        recorded
    }
}

private actor WorkflowWorkspaceRunner: WorkspaceCommandRunning {
    private var contextBuilderResponse = "[]"
    private var contextBuilderTurn = 0
    private var recordedOraclePrompts: [String] = []

    func setContextBuilderResponse(_ value: String) {
        contextBuilderResponse = value
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        let prompt = arguments.last ?? ""
        if prompt.contains("Context Builder") {
            contextBuilderTurn = 1
            return contextBuilderResponse
        }
        if prompt.contains("<tool_result>") {
            contextBuilderTurn += 1
            if contextBuilderTurn == 2 {
                return "{\"tool\":\"prompt\",\"args\":{\"op\":\"set\",\"text\":\"Use the selected important context.\"}}"
            }
            return "{\"tool\":\"finish\",\"args\":{\"response\":\"builder plan\"}}"
        }
        if prompt.contains("RepoPrompt Oracle") {
            recordedOraclePrompts.append(prompt)
            return "oracle response"
        }
        return "provider 1.0"
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        maximumBytes: Int,
        launchValidation: @escaping @Sendable () throws -> Void,
        launchAcknowledgement: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        try launchValidation()
        try await launchAcknowledgement()
        return try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            maximumBytes: maximumBytes
        )
    }

    func oraclePrompts() -> [String] {
        recordedOraclePrompts
    }
}

private actor QuestionWorkspaceRunner: WorkspaceCommandRunning {
    private(set) var receivedAnswer = false

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        let prompt = arguments.last ?? ""
        if prompt.contains("Context Builder") {
            return #"{"tool":"ask_user","args":{"question":"Which target?","choices":["service","app"]}}"#
        }
        if prompt.contains("Use the service target") {
            receivedAnswer = true
            return #"{"tool":"finish","args":{}}"#
        }
        throw ServiceAPIError(code: .dependencyUnavailable, message: "unexpected Context Builder prompt")
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        maximumBytes: Int,
        launchValidation: @escaping @Sendable () throws -> Void,
        launchAcknowledgement: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        try launchValidation()
        try await launchAcknowledgement()
        return try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            maximumBytes: maximumBytes
        )
    }
}

private actor BlockingContextBuilderRuntime: ContextBuilderRuntimeService {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var proposal = ContextBuilderRuntimeProposal(selection: [], response: nil, providerSessionID: nil, rawProviderOutput: "")

    func setProposal(_ proposal: ContextBuilderRuntimeProposal) {
        self.proposal = proposal
    }

    func propose(_: ContextBuilderRuntimeRequest) async -> ContextBuilderRuntimeProposal {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return proposal
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
