#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessFilesystemBackend: DomainFilesystemMutationBackend {
    private let context: DirectHeadlessDomainContext

    init(context: DirectHeadlessDomainContext) {
        self.context = context
    }

    func manageFiles(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        guard let action = args["action"]?.stringValue,
              let rawPath = args["path"]?.stringValue
        else {
            throw MCPError.invalidParams("file_actions requires action and path")
        }
        guard ["create", "move", "delete"].contains(action) else {
            throw MCPError.invalidParams("unknown file_actions action: \(action)")
        }
        let allowMissing = action == "create"
        let source = try context.resolvePath(rawPath, roots: snapshot.roots, allowMissingLeaf: allowMissing)
        var targets = [source.path]
        var destination: URL?
        if action == "move" {
            guard let rawDestination = args["new_path"]?.stringValue else {
                throw MCPError.invalidParams("move requires new_path")
            }
            let resolved = try context.resolvePath(rawDestination, roots: snapshot.roots, allowMissingLeaf: true)
            destination = resolved
            targets.append(resolved.path)
        }
        let manager = FileManager.default
        switch action {
        case "create":
            if manager.fileExists(atPath: source.path), args["if_exists"]?.stringValue != "overwrite" {
                throw MCPError.invalidParams("path already exists: \(source.path)")
            }
        case "move":
            guard let destination else { throw MCPError.invalidParams("move requires new_path") }
            guard manager.fileExists(atPath: source.path) else { throw MCPError.invalidParams("path does not exist") }
            guard !manager.fileExists(atPath: destination.path) else { throw MCPError.invalidParams("destination exists") }
        case "delete":
            guard manager.fileExists(atPath: source.path) else { throw MCPError.invalidParams("path does not exist") }
        default:
            preconditionFailure("file_actions operation was validated above")
        }
        try await admit(targets, roots: snapshot.roots)
        try await MCPDomainMutationCommitContext.willCommit()
        switch action {
        case "create":
            let exists = manager.fileExists(atPath: source.path)
            if exists, args["if_exists"]?.stringValue != "overwrite" {
                throw MCPError.invalidParams("path already exists: \(source.path)")
            }
            try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (args["content"]?.stringValue ?? "").write(to: source, atomically: true, encoding: .utf8)
        case "move":
            guard let destination else { throw MCPError.invalidParams("move requires new_path") }
            guard manager.fileExists(atPath: source.path) else { throw MCPError.invalidParams("path does not exist") }
            guard !manager.fileExists(atPath: destination.path) else { throw MCPError.invalidParams("destination exists") }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: source, to: destination)
        case "delete":
            guard manager.fileExists(atPath: source.path) else { throw MCPError.invalidParams("path does not exist") }
            try moveToTrash(source, using: manager)
        default:
            throw MCPError.invalidParams("unknown file_actions action: \(action)")
        }
        return try .object([
            "action": .string(action),
            "path": .string(source.path),
            "new_path": destination.map { .string($0.path) } ?? .null,
            "operation_id": args["operation_id"] ?? .null,
            "applied": .bool(true)
        ])
    }

    func applyFileEdits(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        let parsed = try ApplyEditsRequestBuilder().build(from: args)
        let allowsCreation: Bool = if case let .rewrite(_, onMissing) = parsed.mode {
            onMissing == .create
        } else {
            false
        }
        let url = try context.resolvePath(
            parsed.path,
            roots: snapshot.roots,
            allowMissingLeaf: allowsCreation
        )
        let canonicalRequest = ApplyEditsRequest(
            path: url.path,
            mode: parsed.mode,
            verbose: parsed.verbose
        )
        let host = DirectHeadlessFileEditHost(target: url, roots: snapshot.roots)
        let result = try await ApplyEditsService(engine: .default, host: host).run(
            canonicalRequest,
            options: ApplyEditsExecutionOptions(includeToolCardUnifiedDiff: false)
        )
        var payload: [String: Value] = [
            "path": .string(url.path),
            "operation_id": args["operation_id"] ?? .null,
            "status": .string(result.status.rawValue),
            "edits_requested": .int(result.editsRequested),
            "edits_applied": .int(result.editsApplied),
            "created": .bool(result.fileCreated),
            "overwritten": .bool(result.fileOverwritten),
            "note": result.note.map(Value.string) ?? .null,
            "mutation_acknowledgement": .object([
                "operation_id": args["operation_id"] ?? .null,
                "freshness": .string("fresh"),
                "mutation": .string("applied")
            ])
        ]
        if let stats = result.stats {
            payload["stats"] = .object([
                "lines_changed": .int(stats.linesChanged),
                "chunks": .int(stats.chunks)
            ])
        }
        if let outcomes = result.outcomes {
            payload["outcomes"] = .array(outcomes.map { outcome in
                .object([
                    "index": .int(outcome.index),
                    "status": .string(outcome.status),
                    "error": outcome.error.map(Value.string) ?? .null
                ])
            })
        }
        if let unifiedDiff = result.unifiedDiff {
            payload["diff"] = .string(unifiedDiff)
        }
        return try .object(payload)
    }

    private func admit(_ paths: [String], roots: [URL]) async throws {
        let mappings = roots.map {
            DomainMutationPhysicalRootMapping(canonicalRoot: $0.path, physicalRoot: $0.path)
        }
        try await MCPDomainMutationCommitContext.admitPhysicalTargets(paths, rootMappings: mappings)
    }

    private func moveToTrash(_ source: URL, using manager: FileManager) throws {
        #if canImport(Darwin)
            var resultingURL: NSURL?
            try manager.trashItem(at: source, resultingItemURL: &resultingURL)
        #else
            let environment = ProcessInfo.processInfo.environment
            let dataHome = environment["XDG_DATA_HOME"].flatMap { value in
                value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
            } ?? manager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
            let trashRoot = dataHome.appendingPathComponent("Trash", isDirectory: true)
            let filesDirectory = trashRoot.appendingPathComponent("files", isDirectory: true)
            let infoDirectory = trashRoot.appendingPathComponent("info", isDirectory: true)
            try manager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            try manager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)

            let baseName = source.lastPathComponent.isEmpty ? "item" : source.lastPathComponent
            var trashName = baseName
            while manager.fileExists(atPath: filesDirectory.appendingPathComponent(trashName).path)
                || manager.fileExists(atPath: infoDirectory.appendingPathComponent("\(trashName).trashinfo").path)
            {
                trashName = "\(baseName).\(UUID().uuidString.lowercased())"
            }
            let destination = filesDirectory.appendingPathComponent(trashName)
            let infoURL = infoDirectory.appendingPathComponent("\(trashName).trashinfo")
            let encodedPath = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.path
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let info = "[Trash Info]\nPath=\(encodedPath)\nDeletionDate=\(formatter.string(from: Date()))\n"
            try info.write(to: infoURL, atomically: true, encoding: .utf8)
            do {
                do {
                    try manager.moveItem(at: source, to: destination)
                } catch {
                    try manager.copyItem(at: source, to: destination)
                    do {
                        try manager.removeItem(at: source)
                    } catch {
                        try? manager.removeItem(at: destination)
                        throw error
                    }
                }
            } catch {
                try? manager.removeItem(at: infoURL)
                throw error
            }
        #endif
    }
}

private actor DirectHeadlessFileEditHost: FileEditHost {
    private let target: URL
    private let rootMappings: [DomainMutationPhysicalRootMapping]
    private var expectedDigest: String?
    private var expectedMissing = false

    init(target: URL, roots: [URL]) {
        self.target = target
        rootMappings = roots.map {
            DomainMutationPhysicalRootMapping(canonicalRoot: $0.path, physicalRoot: $0.path)
        }
    }

    func fileExists(path: String) async -> Bool {
        guard path == target.path else { return false }
        let exists = FileManager.default.fileExists(atPath: target.path)
        if !exists { expectedMissing = true }
        return exists
    }

    func readText(path: String) async throws -> String {
        guard path == target.path else {
            throw MCPError.invalidParams("apply_edits host rejected a non-target path")
        }
        let data = try Data(contentsOf: target)
        expectedDigest = DomainContentDigest.sha256(data)
        expectedMissing = false
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError.invalidParams("apply_edits requires a UTF-8 text file")
        }
        return text
    }

    func writeText(path: String, content: String, overwrite: Bool) async throws {
        guard path == target.path else {
            throw MCPError.invalidParams("apply_edits host rejected a non-target path")
        }
        try await MCPDomainMutationCommitContext.admitPhysicalTargets(
            [target.path],
            rootMappings: rootMappings
        )
        let manager = FileManager.default
        try validateCurrentRevision(manager: manager, overwrite: overwrite)
        try await MCPDomainMutationCommitContext.willCommit()
        // Recheck synchronously after the durable boundary and immediately before atomic replacement.
        try validateCurrentRevision(manager: manager, overwrite: overwrite)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: target, atomically: true, encoding: .utf8)
    }

    private func validateCurrentRevision(manager: FileManager, overwrite: Bool) throws {
        if overwrite {
            guard let expectedDigest,
                  let current = try? Data(contentsOf: target),
                  DomainContentDigest.sha256(current) == expectedDigest
            else {
                throw MCPError.internalError("apply_edits revision conflict: file changed after preview")
            }
        } else {
            guard expectedMissing, !manager.fileExists(atPath: target.path) else {
                throw MCPError.internalError("apply_edits revision conflict: file was created concurrently")
            }
        }
    }
}

actor DirectHeadlessVersionControlBackend: DomainVersionControlCapabilityBackend {
    private struct MergeOperation {
        let id: UUID
        let sourceRoot: URL
        let sourceHead: String
        let sourceRepositoryIdentity: String
        let sourceWorktreeIdentity: String
        let targetRoot: URL
        let targetHead: String
        let targetRepositoryIdentity: String
        let targetWorktreeIdentity: String
    }

    private let runtime: MCPDomainRuntime
    private let context: DirectHeadlessDomainContext
    private var mergeOperations: [UUID: MergeOperation] = [:]

    init(runtime: MCPDomainRuntime, context: DirectHeadlessDomainContext) {
        self.runtime = runtime
        self.context = context
    }

    func inspectGit(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        let roots = try resolveGitRoots(args: args, snapshot: snapshot)
        let op = args["op"]?.stringValue ?? "status"
        var outputs: [Value] = []
        for root in roots {
            let command: [String]
            switch op {
            case "status": command = ["status", "--short", "--branch"]
            case "log": command = ["log", "--oneline", "-n", String(max(1, min(args["count"]?.intValue ?? 10, 100)))]
            case "show": command = ["show", "--no-ext-diff", "--no-textconv", args["ref"]?.stringValue ?? "HEAD"]
            case "blame":
                guard let path = args["path"]?.stringValue else { throw MCPError.invalidParams("blame requires path") }
                command = ["blame", "--", path]
            case "diff":
                command = ["diff", "--no-ext-diff", "--no-textconv", "--color=never"]
            default: throw MCPError.invalidParams("unknown git op: \(op)")
            }
            let output = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", root.path] + command)
            outputs.append(.object(["repo_root": .string(root.path), "output": .string(output)]))
        }
        return try .object(["op": .string(op), "repositories": .array(outputs)])
    }

    func manageWorktree(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let snapshot = try await context.snapshot(for: request)
        guard let repo = snapshot.roots.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }) else {
            throw MCPError.invalidParams("no Git repository is bound")
        }
        let op = args["op"]?.stringValue ?? "list"
        switch op {
        case "list":
            let output = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", repo.path, "worktree", "list", "--porcelain"])
            return try .object(["op": .string(op), "output": .string(output)])
        case "show":
            let output = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", repo.path, "worktree", "list", "--porcelain"])
            return try .object(["op": .string(op), "output": .string(output)])
        case "create":
            guard let path = args["path"]?.stringValue else { throw MCPError.invalidParams("create requires path") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            try await MCPDomainMutationCommitContext.admitPhysicalTargets(
                [repo.path, url.path],
                rootMappings: Self.mutationRootMappings(workspaceRoots: snapshot.roots)
            )
            try await MCPDomainMutationCommitContext.willCommit()
            var command = ["-C", repo.path, "worktree", "add"]
            if let branch = args["branch"]?.stringValue { command += ["-b", branch] }
            command.append(url.path)
            if let base = args["base_ref"]?.stringValue { command.append(base) }
            let output = try await DirectProcess.run("/usr/bin/git", arguments: command)
            return try .object(["op": .string(op), "path": .string(url.path), "output": .string(output)])
        case "bind", "select":
            let sessionID = try sessionID(args: args, request: request)
            let worktree = try await resolveWorktree(args: args, repository: repo, roots: snapshot.roots)
            let repositoryID = DomainContentDigest.sha256(Data(repo.path.utf8))
            let branch = try? await gitLine(at: worktree, arguments: ["branch", "--show-current"])
            let head = try? await gitLine(at: worktree, arguments: ["rev-parse", "HEAD"])
            let binding = AgentSessionWorktreeBinding(
                id: "\(repositoryID):\(worktree.path)",
                repositoryID: repositoryID,
                repoKey: repo.path,
                logicalRootPath: repo.path,
                logicalRootName: repo.lastPathComponent,
                worktreeID: DomainContentDigest.sha256(Data(worktree.path.utf8)),
                worktreeRootPath: worktree.path,
                worktreeName: worktree.lastPathComponent,
                branch: branch,
                head: head,
                visualLabel: args["label"]?.stringValue,
                visualColorHex: args["color"]?.stringValue,
                source: "headless-manage-worktree"
            )
            try await MCPDomainMutationCommitContext.willCommit()
            let revision = try await runtime.agentWorktreeBindingStore.upsert(sessionID: sessionID, binding: binding)
            return try .object([
                "op": .string(op),
                "session_id": .string(sessionID.uuidString),
                "binding": bindingValue(binding),
                "revision": .int(Int(revision))
            ])
        case "unbind":
            let sessionID = try sessionID(args: args, request: request)
            try await MCPDomainMutationCommitContext.willCommit()
            let revision = try await runtime.agentWorktreeBindingStore.remove(
                sessionID: sessionID,
                repositoryID: args["repo_root"]?.stringValue
            )
            return try await .object([
                "op": .string(op),
                "session_id": .string(sessionID.uuidString),
                "revision": .int(Int(revision)),
                "bindings": .array((runtime.agentWorktreeBindingStore.bindings(sessionID: sessionID)).map(bindingValue))
            ])
        case "preview":
            let target = try await resolveMergeTarget(args: args, repository: repo, roots: snapshot.roots)
            let sourceHead = try await gitLine(at: repo, arguments: ["rev-parse", "HEAD"])
            let targetHead = try await gitLine(at: target, arguments: ["rev-parse", "HEAD"])
            let sourceRepositoryIdentity = try await gitCommonDirectory(at: repo)
            let sourceWorktreeIdentity = try await gitDirectory(at: repo)
            let targetRepositoryIdentity = try await gitCommonDirectory(at: target)
            let targetWorktreeIdentity = try await gitDirectory(at: target)
            let id = UUID()
            mergeOperations[id] = MergeOperation(
                id: id,
                sourceRoot: repo,
                sourceHead: sourceHead,
                sourceRepositoryIdentity: sourceRepositoryIdentity,
                sourceWorktreeIdentity: sourceWorktreeIdentity,
                targetRoot: target,
                targetHead: targetHead,
                targetRepositoryIdentity: targetRepositoryIdentity,
                targetWorktreeIdentity: targetWorktreeIdentity
            )
            let patch = try await DirectProcess.run(
                "/usr/bin/git",
                arguments: ["-C", target.path, "diff", "--no-ext-diff", "--color=never", "\(targetHead)..\(sourceHead)"]
            )
            return try .object([
                "op": .string(op),
                "operation_id": .string(id.uuidString),
                "source": .string(repo.path),
                "target": .string(target.path),
                "patch": .string(patch)
            ])
        case "apply":
            let operation = try mergeOperation(args)
            let initialTargets = try await revalidatedMergeMutationTargets(
                operation,
                repository: repo,
                request: request
            )
            try await admitMergeMutation(initialTargets)
            try await MCPDomainMutationCommitContext.willCommit()
            let targets = try await revalidatedMergeMutationTargets(
                operation,
                repository: repo,
                request: request
            )
            let message = args["commit_message"]?.stringValue ?? "Merge headless worktree \(operation.sourceHead.prefix(12))"
            let output = try await DirectProcess.run(
                "/usr/bin/git",
                arguments: Self.mergeMutationArguments(
                    targetRoot: targets.targetRoot,
                    gitDirectory: targets.targetGitDirectory,
                    command: ["merge", "--no-ff", "-m", message, operation.sourceHead]
                )
            )
            mergeOperations.removeValue(forKey: operation.id)
            return try .object(["op": .string(op), "operation_id": .string(operation.id.uuidString), "output": .string(output)])
        case "status":
            if let raw = args["operation_id"]?.stringValue, let id = UUID(uuidString: raw), let operation = mergeOperations[id] {
                let output = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", operation.targetRoot.path, "status", "--short", "--branch"])
                return try .object(["op": .string(op), "operation_id": .string(id.uuidString), "output": .string(output)])
            }
            let bindings: [Value] = if let sessionID = try? sessionID(args: args, request: request) {
                await runtime.agentWorktreeBindingStore.bindings(sessionID: sessionID).map(bindingValue)
            } else {
                []
            }
            return try .object(["op": .string(op), "bindings": .array(bindings)])
        case "continue", "abort":
            let operation = try mergeOperation(args)
            let initialTargets = try await revalidatedMergeMutationTargets(
                operation,
                repository: repo,
                request: request
            )
            try await admitMergeMutation(initialTargets)
            try await MCPDomainMutationCommitContext.willCommit()
            let targets = try await revalidatedMergeMutationTargets(
                operation,
                repository: repo,
                request: request
            )
            let command = op == "continue" ? ["merge", "--continue"] : ["merge", "--abort"]
            let output = try await DirectProcess.run(
                "/usr/bin/git",
                arguments: Self.mergeMutationArguments(
                    targetRoot: targets.targetRoot,
                    gitDirectory: targets.targetGitDirectory,
                    command: command
                )
            )
            mergeOperations.removeValue(forKey: operation.id)
            return try .object(["op": .string(op), "operation_id": .string(operation.id.uuidString), "output": .string(output)])
        default:
            throw MCPError.invalidParams("unknown manage_worktree op: \(op)")
        }
    }

    nonisolated static func mutationRootMappings(
        workspaceRoots: [URL]
    ) -> [DomainMutationPhysicalRootMapping] {
        workspaceRoots.map { root in
            let path = root.standardizedFileURL.path
            return DomainMutationPhysicalRootMapping(canonicalRoot: path, physicalRoot: path)
        }
    }

    private struct MergeMutationTargets {
        let sourceRoot: URL
        let targetRoot: URL
        let targetGitDirectory: String
        let roots: [URL]
    }

    nonisolated static func revalidateMergeEndpointPaths(
        sourceRoot: URL,
        targetRoot: URL,
        roots: [URL],
        listedWorktrees: [URL]
    ) throws -> (source: URL, target: URL) {
        let source = try authorizeWorktreePath(sourceRoot, roots: roots)
        let target = try authorizeWorktreePath(targetRoot, roots: roots)
        let livePaths = Set(listedWorktrees.map { Self.canonicalWorktreePath($0) })
        guard livePaths.contains(source.path) else {
            throw MCPError.invalidRequest("merge preview source endpoint is no longer a listed worktree")
        }
        guard livePaths.contains(target.path) else {
            throw MCPError.invalidRequest("merge preview target endpoint is no longer a listed worktree")
        }
        return (source, target)
    }

    private func revalidatedMergeMutationTargets(
        _ operation: MergeOperation,
        repository: URL,
        request: DomainPhysicalToolRequest
    ) async throws -> MergeMutationTargets {
        let snapshot = try await context.snapshot(for: request)
        let listed = try await listedWorktrees(repository: repository)
        let endpoints = try Self.revalidateMergeEndpointPaths(
            sourceRoot: operation.sourceRoot,
            targetRoot: operation.targetRoot,
            roots: snapshot.roots,
            listedWorktrees: listed
        )
        let sourceHead = try await gitLine(at: endpoints.source, arguments: ["rev-parse", "HEAD"])
        let targetHead = try await gitLine(at: endpoints.target, arguments: ["rev-parse", "HEAD"])
        let sourceRepositoryIdentity = try await gitCommonDirectory(at: endpoints.source)
        let sourceWorktreeIdentity = try await gitDirectory(at: endpoints.source)
        let targetRepositoryIdentity = try await gitCommonDirectory(at: endpoints.target)
        let targetWorktreeIdentity = try await gitDirectory(at: endpoints.target)
        try Self.validateMergeEndpointIdentity(
            expectedHead: operation.sourceHead,
            currentHead: sourceHead,
            expectedRepositoryIdentity: operation.sourceRepositoryIdentity,
            currentRepositoryIdentity: sourceRepositoryIdentity,
            expectedWorktreeIdentity: operation.sourceWorktreeIdentity,
            currentWorktreeIdentity: sourceWorktreeIdentity
        )
        try Self.validateMergeEndpointIdentity(
            expectedHead: operation.targetHead,
            currentHead: targetHead,
            expectedRepositoryIdentity: operation.targetRepositoryIdentity,
            currentRepositoryIdentity: targetRepositoryIdentity,
            expectedWorktreeIdentity: operation.targetWorktreeIdentity,
            currentWorktreeIdentity: targetWorktreeIdentity
        )
        return MergeMutationTargets(
            sourceRoot: endpoints.source,
            targetRoot: endpoints.target,
            targetGitDirectory: targetWorktreeIdentity,
            roots: snapshot.roots
        )
    }

    nonisolated static func mergeMutationArguments(
        targetRoot: URL,
        gitDirectory: String,
        command: [String]
    ) -> [String] {
        ["--git-dir", gitDirectory, "--work-tree", canonicalWorktreePath(targetRoot)] + command
    }

    nonisolated static func validateMergeEndpointIdentity(
        expectedHead: String,
        currentHead: String,
        expectedRepositoryIdentity: String,
        currentRepositoryIdentity: String,
        expectedWorktreeIdentity: String,
        currentWorktreeIdentity: String
    ) throws {
        guard expectedHead == currentHead,
              expectedRepositoryIdentity == currentRepositoryIdentity,
              expectedWorktreeIdentity == currentWorktreeIdentity
        else {
            throw MCPError.invalidRequest("merge preview endpoint identity changed; create a new preview")
        }
    }

    private nonisolated static func canonicalWorktreePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func admitMergeMutation(_ targets: MergeMutationTargets) async throws {
        try await MCPDomainMutationCommitContext.admitPhysicalTargets(
            [targets.sourceRoot.path, targets.targetRoot.path],
            rootMappings: Self.mutationRootMappings(workspaceRoots: targets.roots)
        )
    }

    private func sessionID(
        args: [String: Value],
        request: DomainPhysicalToolRequest
    ) throws -> UUID {
        if let raw = args["session_id"]?.stringValue, let id = UUID(uuidString: raw) { return id }
        if let runID = request.securityContext?.principal.runID { return runID }
        throw MCPError.invalidParams("manage_worktree requires session_id outside a run-scoped child connection")
    }

    private func bindingValue(_ binding: AgentSessionWorktreeBinding) -> Value {
        .object([
            "id": .string(binding.id),
            "repository_id": .string(binding.repositoryID),
            "repo_key": .string(binding.repoKey),
            "logical_root": .string(binding.logicalRootPath),
            "worktree_id": .string(binding.worktreeID),
            "worktree_root": .string(binding.worktreeRootPath),
            "worktree_name": binding.worktreeName.map(Value.string) ?? .null,
            "branch": binding.branch.map(Value.string) ?? .null,
            "head": binding.head.map(Value.string) ?? .null,
            "label": binding.visualLabel.map(Value.string) ?? .null,
            "color": binding.visualColorHex.map(Value.string) ?? .null
        ])
    }

    nonisolated static func authorizeWorktreePath(_ path: URL, roots: [URL]) throws -> URL {
        try DirectHeadlessDomainContext.resolvePath(path.path, roots: roots)
    }

    private func resolveWorktree(
        args: [String: Value],
        repository: URL,
        roots: [URL]
    ) async throws -> URL {
        let selector = args["worktree"]?.stringValue
            ?? args["worktree_id"]?.stringValue
            ?? "@current"
        if selector.hasPrefix("/") {
            let url = try Self.authorizeWorktreePath(URL(fileURLWithPath: selector), roots: roots)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MCPError.invalidParams("worktree does not exist: \(selector)")
            }
            return url
        }
        let worktrees = try await listedWorktrees(repository: repository)
        if selector == "@current" {
            return try Self.authorizeWorktreePath(repository, roots: roots)
        }
        if selector == "@main" {
            return try Self.authorizeWorktreePath(worktrees.first ?? repository, roots: roots)
        }
        let normalizedBranch = selector.hasPrefix("@branch:") ? String(selector.dropFirst("@branch:".count)) : selector
        let normalizedID = normalizedBranch.replacingOccurrences(of: "@id:", with: "")
        for worktree in worktrees {
            let branch = try? await gitLine(at: worktree, arguments: ["branch", "--show-current"])
            if worktree.lastPathComponent == normalizedBranch
                || DomainContentDigest.sha256(Data(worktree.path.utf8)) == normalizedID
                || branch == normalizedBranch
            {
                return try Self.authorizeWorktreePath(worktree, roots: roots)
            }
        }
        throw MCPError.invalidParams("unknown worktree selector: \(selector)")
    }

    private func resolveMergeTarget(
        args: [String: Value],
        repository: URL,
        roots: [URL]
    ) async throws -> URL {
        var targetArgs = args
        targetArgs["worktree"] = args["target"] ?? .string("@main")
        return try await resolveWorktree(args: targetArgs, repository: repository, roots: roots)
    }

    private func listedWorktrees(repository: URL) async throws -> [URL] {
        let output = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", repository.path, "worktree", "list", "--porcelain"]
        )
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("worktree ") else { return nil }
            return URL(fileURLWithPath: String(line.dropFirst("worktree ".count))).standardizedFileURL
        }
    }

    private func gitLine(at root: URL, arguments: [String]) async throws -> String {
        try await DirectProcess.run("/usr/bin/git", arguments: ["-C", root.path] + arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitCommonDirectory(at root: URL) async throws -> String {
        let raw = try await gitLine(at: root, arguments: ["rev-parse", "--git-common-dir"])
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: root.path).appendingPathComponent(raw)
        return Self.canonicalWorktreePath(url)
    }

    private func gitDirectory(at root: URL) async throws -> String {
        let raw = try await gitLine(at: root, arguments: ["rev-parse", "--git-dir"])
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: root.path).appendingPathComponent(raw)
        return Self.canonicalWorktreePath(url)
    }

    private func mergeOperation(_ args: [String: Value]) throws -> MergeOperation {
        guard let raw = args["operation_id"]?.stringValue,
              let id = UUID(uuidString: raw),
              let operation = mergeOperations[id]
        else {
            throw MCPError.invalidParams("operation_id must identify a live merge preview")
        }
        return operation
    }

    private func resolveGitRoots(
        args: [String: Value],
        snapshot: DirectHeadlessDomainContext.Snapshot
    ) throws -> [URL] {
        if let root = args["repo_root"]?.stringValue {
            return try [context.resolvePath(root, roots: snapshot.roots)]
        }
        if let roots = args["repo_roots"]?.arrayValue?.compactMap(\.stringValue) {
            return try roots.map { try context.resolvePath($0, roots: snapshot.roots) }
        }
        return snapshot.roots.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path)
        }
    }
}

actor DirectHeadlessConversationBackend: DomainConversationCapabilityBackend {
    private let coordinator: DirectHeadlessOracleCoordinator

    init(coordinator: DirectHeadlessOracleCoordinator) {
        self.coordinator = coordinator
    }

    func accessOracleUtilities(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let op = args["op"]?.stringValue ?? "models"
        return try await .mcp(coordinator.utilityResult(
            operation: op,
            limit: args["limit"]?.intValue ?? 50,
            request: request
        ))
    }

    func startOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        guard let message = args["message"]?.stringValue, !message.isEmpty else {
            throw MCPError.invalidParams("ask_oracle requires message")
        }
        return try await .mcp(coordinator.start(
            providerID: args["provider"]?.stringValue,
            message: message,
            model: args["model"]?.stringValue,
            mode: args["mode"]?.stringValue ?? "chat",
            request: request
        ))
    }

    func continueOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        guard let message = args["message"]?.stringValue, !message.isEmpty else {
            throw MCPError.invalidParams("oracle_send requires message")
        }
        let forceNew = args["new_chat"]?.boolValue ?? false
        let id: UUID?
        if !forceNew, let rawID = args["chat_id"]?.stringValue {
            guard let parsed = UUID(uuidString: rawID) else {
                throw MCPError.invalidParams("chat_id must be a UUID")
            }
            id = parsed
        } else {
            id = nil
        }
        return try await .mcp(coordinator.send(
            providerID: args["provider"]?.stringValue,
            requestedID: id,
            forceNew: forceNew,
            message: message,
            model: args["model"]?.stringValue,
            mode: args["mode"]?.stringValue ?? "chat",
            request: request
        ))
    }

    func readOracleLog(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let id: UUID?
        if let rawID = args["chat_id"]?.stringValue {
            guard let parsed = UUID(uuidString: rawID) else {
                throw MCPError.invalidParams("chat_id must be a UUID")
            }
            id = parsed
        } else {
            id = nil
        }
        return try await .mcp(coordinator.conversationLog(
            id: id,
            limit: args["limit"]?.intValue ?? 8,
            request: request
        ))
    }

    func buildContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        guard let instructions = args["instructions"]?.stringValue, !instructions.isEmpty else {
            throw MCPError.invalidParams("context_builder requires instructions")
        }
        return try await .mcp(coordinator.buildContext(
            providerID: args["provider"]?.stringValue,
            instructions: instructions,
            model: args["model"]?.stringValue,
            responseType: args["response_type"]?.stringValue,
            request: request
        ))
    }

    func requestUserInput(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        throw MCPError.invalidRequest("interaction_unavailable: no elicitation-capable client is registered")
    }
}

actor DirectHeadlessAgentBackend: DomainAgentCapabilityBackend {
    private let coordinator: DirectHeadlessProviderCoordinator

    init(coordinator: DirectHeadlessProviderCoordinator) {
        self.coordinator = coordinator
    }

    func explore(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        return try await dispatchLifecycle(args: args, request: request, defaultAgent: "explore")
    }

    func run(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        return try await dispatchLifecycle(args: args, request: request, defaultAgent: "pair")
    }

    func manage(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let op = args["op"]?.stringValue ?? "list_agents"
        switch op {
        case "list_agents", "providers":
            let providers = await coordinator.providerCatalog().map(\.value)
            return try .object(["agents": .array(providers), "backend": .string("headless")])
        case "list", "list_sessions":
            return try await .object(["sessions": .array(coordinator.listAgents()), "backend": .string("headless")])
        case "cancel":
            let sessionID = try Self.sessionID(args)
            await coordinator.cancelAgent(sessionID: sessionID)
            return try .object(["session_id": .string(sessionID.uuidString), "cancelled": .bool(true)])
        default:
            throw MCPError.invalidRequest("unsupported standalone agent_manage op: \(op)")
        }
    }

    func shareThoughts(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let sessionID = try Self.sessionID(args, request: request)
        guard let text = args["text"]?.stringValue ?? args["thoughts"]?.stringValue else {
            throw MCPError.invalidParams("agent_share_thoughts requires text")
        }
        return try await .mcp(coordinator.shareThoughts(sessionID: sessionID, text: text))
    }

    func publishStatus(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let sessionID = try Self.sessionID(args, request: request)
        return try await .mcp(coordinator.updateStatus(
            sessionID: sessionID,
            name: args["session_name"]?.stringValue
        ))
    }

    func waitForInstruction(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let sessionID = try Self.sessionID(args, request: request)
        let snapshot = await coordinator.waitAgent(
            sessionID: sessionID,
            timeout: args["timeout"]?.doubleValue ?? 120
        )
        return try .mcp(snapshot.toValue())
    }

    private func dispatchLifecycle(
        args: [String: Value],
        request: DomainPhysicalToolRequest,
        defaultAgent: String
    ) async throws -> DomainPhysicalToolResult {
        let op = args["op"]?.stringValue ?? "start"
        switch op {
        case "start":
            var normalized = args
            if normalized["model_id"] == nil { normalized["model_id"] = .string(defaultAgent) }
            return try await .mcp(coordinator.startAgent(args: normalized, request: request))
        case "poll":
            let sessionID = try Self.sessionID(args)
            return try await .mcp(coordinator.pollAgent(
                sessionID: sessionID,
                timeout: args["timeout"]?.doubleValue ?? 0
            ).toValue())
        case "wait":
            let sessionID = try Self.sessionID(args)
            return try await .mcp(coordinator.waitAgent(
                sessionID: sessionID,
                timeout: args["timeout"]?.doubleValue ?? 120
            ).toValue())
        case "cancel":
            let sessionID = try Self.sessionID(args)
            await coordinator.cancelAgent(sessionID: sessionID)
            return try .object(["session_id": .string(sessionID.uuidString), "cancelled": .bool(true)])
        default:
            throw MCPError.invalidRequest("unsupported standalone agent operation: \(op)")
        }
    }

    private static func sessionID(
        _ args: [String: Value],
        request: DomainPhysicalToolRequest? = nil
    ) throws -> UUID {
        if let raw = args["session_id"]?.stringValue, let id = UUID(uuidString: raw) {
            return id
        }
        if let runID = request?.securityContext?.principal.runID {
            return runID
        }
        throw MCPError.invalidParams("session_id must be a UUID when no run-scoped principal is present")
    }
}

actor DirectHeadlessHistoryBackend: DomainHistoryCapabilityBackend {
    private let runtime: MCPDomainRuntime
    private let formatter = ISO8601DateFormatter()

    init(runtime: MCPDomainRuntime) {
        self.runtime = runtime
    }

    func inspectHistory(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let op = args["op"]?.stringValue ?? "list_sessions"
        let allMetadata = await runtime.agentSessionStore.restoredMetadata()
        let sessionFilter = args["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let metadata = sessionFilter.map { id in allMetadata.filter { $0.sessionID == id } } ?? allMetadata
        let limit = max(1, min(args["limit"]?.intValue ?? 30, 100))
        switch op {
        case "list_sessions":
            let values = metadata.prefix(limit).map(sessionValue)
            return try .object([
                "sessions": .array(Array(values)),
                "truncated": .bool(metadata.count > limit),
                "scan_truncated": .bool(false),
                "profile": .string(runtime.configuration.profileIdentifier)
            ])
        case "get_session":
            guard let rawID = args["session_id"]?.stringValue,
                  let id = UUID(uuidString: rawID),
                  let found = allMetadata.first(where: { $0.sessionID == id })
            else {
                return try .object(["error": .string("Session was not found in this isolated headless profile")])
            }
            return try .object([
                "session": sessionValue(found),
                "turns": .array([]),
                "transcript_available": .bool(false)
            ])
        case "search":
            guard let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty
            else {
                throw MCPError.invalidParams("history search requires query")
            }
            let matches = metadata.filter {
                $0.sessionID.uuidString.localizedCaseInsensitiveContains(query)
                    || $0.state.rawValue.localizedCaseInsensitiveContains(query)
            }.prefix(limit).map { item in
                Value.object([
                    "session_id": .string(item.sessionID.uuidString),
                    "snippet": .string("Standalone session \(item.state.rawValue)"),
                    "updated_at": .string(formatter.string(from: item.updatedAt))
                ])
            }
            return try .object([
                "matches": .array(Array(matches)),
                "truncated": .bool(false),
                "scan_truncated": .bool(false)
            ])
        case "time":
            guard let groupBy = args["group_by"]?.stringValue,
                  ["day", "week", "month", "session", "workspace"].contains(groupBy)
            else {
                throw MCPError.invalidParams("history time requires group_by")
            }
            let groups = timeGroups(metadata: metadata, groupBy: groupBy).prefix(limit)
            return try .object([
                "group_by": .string(groupBy),
                "groups": .array(Array(groups)),
                "scan_truncated": .bool(false)
            ])
        default:
            throw MCPError.invalidParams("unknown history op: \(op)")
        }
    }

    private func sessionValue(_ metadata: DomainAgentSessionDurableMetadata) -> Value {
        .object([
            "session_id": .string(metadata.sessionID.uuidString),
            "state": .string(metadata.state.rawValue),
            "last_activity": .string(formatter.string(from: metadata.updatedAt)),
            "resumable": .bool(metadata.resumable),
            "runtime_id": .string(metadata.owningRuntimeID.uuidString),
            "runtime_generation": .int(Int(metadata.owningRuntimeGeneration)),
            "turn_count": .int(Int(metadata.lastEpochOrdinal)),
            "files_touched": .array([])
        ])
    }

    private func timeGroups(
        metadata: [DomainAgentSessionDurableMetadata],
        groupBy: String
    ) -> [Value] {
        let calendar = Calendar(identifier: .gregorian)
        var counts: [String: Int] = [:]
        for item in metadata {
            let key: String
            switch groupBy {
            case "session": key = item.sessionID.uuidString
            case "workspace": key = runtime.configuration.profileIdentifier
            case "month":
                let parts = calendar.dateComponents([.year, .month], from: item.updatedAt)
                key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            case "week":
                let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: item.updatedAt)
                key = String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
            default:
                let parts = calendar.dateComponents([.year, .month, .day], from: item.updatedAt)
                key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            }
            counts[key, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { key, count in
            .object(["key": .string(key), "session_count": .int(count), "active_seconds": .int(0)])
        }
    }
}

enum DirectProcess {
    /// Child providers need basic process/configuration context and the explicit private
    /// launch carrier, but must not inherit arbitrary parent credentials or loader controls.
    private static let inheritedEnvironmentKeys: Set<String> = [
        "CODEX_HOME",
        "COLORTERM",
        "HOME",
        "LANG",
        "LOGNAME",
        "NO_COLOR",
        "PATH",
        "SHELL",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TERM",
        "TMPDIR",
        "USER",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME"
    ]

    private static let childLaunchEnvironmentKeys: Set<String> = [
        DomainChildLaunchCarrier.endpointEnvironmentKey,
        DomainChildLaunchCarrier.launchTokenEnvironmentKey,
        DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey,
        DomainChildLaunchCarrier.clientPrincipalEnvironmentKey,
        DomainChildLaunchCarrier.providerIdentifierEnvironmentKey,
        DomainChildLaunchCarrier.runIDEnvironmentKey
    ]

    /// Removes private launch-carrier values from a stored parent environment before
    /// the current request carrier is merged in.
    static func withoutPrivateCarrier(from environment: [String: String]) -> [String: String] {
        environment.filter { !childLaunchEnvironmentKeys.contains($0.key) }
    }

    static func childEnvironment(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = inherited.filter { key, _ in
            inheritedEnvironmentKeys.contains(key) || key.hasPrefix("LC_")
        }
        for (key, value) in overrides where inheritedEnvironmentKeys.contains(key)
            || childLaunchEnvironmentKeys.contains(key)
            || key.hasPrefix("LC_")
        {
            environment[key] = value
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        return environment
    }

    static func run(
        _ executable: String,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) async throws -> String {
        try await DirectProcessInvocation(
            executable: executable,
            arguments: arguments,
            input: input,
            environment: environment,
            currentDirectory: currentDirectory
        ).run()
    }
}

private final class DirectProcessInvocation: @unchecked Sendable {
    private static let outputLimit = 8 * 1024 * 1024
    private static let cancellationGraceInterval: TimeInterval = 1
    private static let cancellationPollInterval: TimeInterval = 0.01

    private let lock = NSLock()
    private let executable: String
    private let arguments: [String]
    private let input: Data?
    private let environment: [String: String]
    private let currentDirectory: URL?
    private var output = Data()
    private var truncated = false
    private var cancellationRequested = false
    private var cancellationStarted = false
    private var cancellationCleanupFinished = false
    private var processID: pid_t = 0
    private var waitOutcome: Result<Int32, Error>?
    private var outputFinished = false
    private var continuation: CheckedContinuation<String, Error>?
    private var inputHandle: FileHandle?
    private var completed = false

    init(
        executable: String,
        arguments: [String],
        input: Data?,
        environment overrides: [String: String],
        currentDirectory: URL?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.input = input
        environment = DirectProcess.childEnvironment(overrides: overrides)
        self.currentDirectory = currentDirectory
    }

    func run() async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try start(continuation: continuation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            requestCancellation()
        }
    }

    private func start(continuation: CheckedContinuation<String, Error>) throws {
        let spawned = try Self.spawn(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            hasInput: input != nil
        )

        lock.lock()
        self.continuation = continuation
        processID = spawned.pid
        inputHandle = spawned.input
        let shouldCancel = cancellationRequested && !cancellationStarted
        if shouldCancel { cancellationStarted = true }
        lock.unlock()

        readOutput(from: spawned.output)
        waitForExit(pid: spawned.pid)
        writeInput(to: spawned.input)
        if shouldCancel { cancelProcessGroup(spawned.pid) }
    }

    private func readOutput(from handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                do {
                    guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
                    append(data)
                } catch {
                    break
                }
            }
            try? handle.close()
            lock.lock()
            outputFinished = true
            lock.unlock()
            finishIfReady()
        }
    }

    private func waitForExit(pid: pid_t) {
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result < 0 && errno == EINTR

            let outcome: Result<Int32, Error>
            if result == pid {
                outcome = .success(status)
            } else {
                outcome = .failure(Self.posixError(operation: "waitpid", code: errno))
            }
            lock.lock()
            waitOutcome = outcome
            lock.unlock()
            finishIfReady()
        }
    }

    private func writeInput(to handle: FileHandle?) {
        guard let handle else { return }
        let input = input ?? Data()
        DispatchQueue.global(qos: .utility).async {
            try? handle.write(contentsOf: input)
            try? handle.close()
        }
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard output.count < Self.outputLimit else {
            truncated = true
            return
        }
        let remaining = Self.outputLimit - output.count
        output.append(data.prefix(remaining))
        if data.count > remaining { truncated = true }
    }

    private func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        let handle = inputHandle
        let pid = processID
        let shouldCancel = pid > 0 && !cancellationStarted && !completed
        if shouldCancel { cancellationStarted = true }
        lock.unlock()
        if shouldCancel { cancelProcessGroup(pid) }
        try? handle?.close()
    }

    private func cancelProcessGroup(_ pid: pid_t) {
        // The provider root is the process-group leader, so this also reaches
        // reparented descendants that still carry the private MCP launch token.
        Self.signalProcessGroup(pid, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).async { [self] in
            let deadline = ProcessInfo.processInfo.systemUptime + Self.cancellationGraceInterval
            while Self.processGroupExists(pid), ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: Self.cancellationPollInterval)
            }
            if Self.processGroupExists(pid) {
                Self.signalProcessGroup(pid, signal: SIGKILL)
            }
            lock.lock()
            cancellationCleanupFinished = true
            lock.unlock()
            finishIfReady()
        }
    }

    private func finishIfReady() {
        let completion: (CheckedContinuation<String, Error>, Result<String, Error>)? = lock.withLock {
            guard !completed,
                  let continuation,
                  outputFinished,
                  let waitOutcome
            else { return nil }
            if cancellationRequested, !cancellationCleanupFinished { return nil }

            completed = true
            self.continuation = nil
            processID = 0
            inputHandle = nil

            if cancellationRequested {
                return (continuation, .failure(CancellationError()))
            }
            switch waitOutcome {
            case let .failure(error):
                return (continuation, .failure(error))
            case let .success(status):
                var text = String(decoding: output, as: UTF8.self)
                if truncated { text += "\n[output truncated at \(Self.outputLimit) bytes]" }
                if Self.exitedSuccessfully(status) {
                    return (continuation, .success(text))
                }
                return (continuation, .failure(MCPError.internalError(
                    text.trimmingCharacters(in: .whitespacesAndNewlines)
                )))
            }
        }
        guard let (continuation, result) = completion else { return }
        continuation.resume(with: result)
    }

    private static func exitedSuccessfully(_ status: Int32) -> Bool {
        let signal = status & 0x7F
        return signal == 0 && ((status >> 8) & 0xFF) == 0
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        guard isSafeProcessGroup(processGroupID) else { return false }
        if systemKill(-processGroupID, signal: 0) == 0 { return true }
        return errno == EPERM
    }

    private static func signalProcessGroup(_ processGroupID: pid_t, signal: Int32) {
        guard isSafeProcessGroup(processGroupID) else { return }
        _ = systemKill(-processGroupID, signal: signal)
    }

    private static func isSafeProcessGroup(_ processGroupID: pid_t) -> Bool {
        processGroupID > 1 && processGroupID != getpgrp()
    }

    @discardableResult
    private static func systemKill(_ pid: pid_t, signal: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.kill(pid, signal)
        #else
            Glibc.kill(pid, signal)
        #endif
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let output: FileHandle
        let input: FileHandle?
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        hasInput: Bool
    ) throws -> SpawnedProcess {
        var outputPipe: [Int32] = [-1, -1]
        var inputPipe: [Int32] = [-1, -1]

        guard systemPipe(&outputPipe) == 0 else {
            throw posixError(operation: "pipe(stdout)", code: errno)
        }
        do {
            try relocatePipeDescriptors(&outputPipe)
            try setCloseOnExec(outputPipe[0])
            try setCloseOnExec(outputPipe[1])
            if hasInput {
                guard systemPipe(&inputPipe) == 0 else {
                    throw posixError(operation: "pipe(stdin)", code: errno)
                }
                try relocatePipeDescriptors(&inputPipe)
                try setCloseOnExec(inputPipe[0])
                try setCloseOnExec(inputPipe[1])
            }
        } catch {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw error
        }

        #if canImport(Darwin)
            var fileActions: posix_spawn_file_actions_t? = nil
        #else
            var fileActions = posix_spawn_file_actions_t()
        #endif
        var result = posix_spawn_file_actions_init(&fileActions)
        guard result == 0 else {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw posixError(operation: "posix_spawn_file_actions_init", code: result)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        func addFileAction(_ operation: String, _ body: () -> Int32) throws {
            let actionResult = body()
            guard actionResult == 0 else {
                closePipe(&outputPipe)
                closePipe(&inputPipe)
                throw posixError(operation: operation, code: actionResult)
            }
        }

        if hasInput {
            try addFileAction("dup2(stdin)") {
                posix_spawn_file_actions_adddup2(&fileActions, inputPipe[0], STDIN_FILENO)
            }
            try addFileAction("close(stdin read)") {
                posix_spawn_file_actions_addclose(&fileActions, inputPipe[0])
            }
            try addFileAction("close(stdin write)") {
                posix_spawn_file_actions_addclose(&fileActions, inputPipe[1])
            }
        } else {
            // Match Foundation.Process: without an explicit input pipe, the
            // child inherits the headless process's standard input.
            try addFileAction("inherit(stdin)") {
                posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDIN_FILENO)
            }
        }
        try addFileAction("dup2(stdout)") {
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO)
        }
        try addFileAction("dup2(stderr)") {
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDERR_FILENO)
        }
        try addFileAction("close(output read)") {
            posix_spawn_file_actions_addclose(&fileActions, outputPipe[0])
        }
        try addFileAction("close(output write)") {
            posix_spawn_file_actions_addclose(&fileActions, outputPipe[1])
        }
        if let currentDirectory {
            result = currentDirectory.path.withCString { path in
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            }
            guard result == 0 else {
                closePipe(&outputPipe)
                closePipe(&inputPipe)
                throw posixError(operation: "chdir(\(currentDirectory.path))", code: result)
            }
        }
        #if canImport(Glibc)
            // Foundation.Process closes unrelated descriptors on Linux. Preserve
            // that boundary so private endpoint/listener FDs cannot reach Codex.
            try addFileAction("closefrom") {
                posix_spawn_file_actions_addclosefrom_np(&fileActions, 3)
            }
        #endif

        #if canImport(Darwin)
            var attributes: posix_spawnattr_t? = nil
        #else
            var attributes = posix_spawnattr_t()
        #endif
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw posixError(operation: "posix_spawnattr_init", code: result)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        result = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard result == 0 else {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw posixError(operation: "posix_spawnattr_setsigdefault", code: result)
        }
        var childSignalMask = sigset_t()
        sigemptyset(&childSignalMask)
        result = posix_spawnattr_setsigmask(&attributes, &childSignalMask)
        guard result == 0 else {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw posixError(operation: "posix_spawnattr_setsigmask", code: result)
        }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw posixError(operation: "posix_spawnattr_setpgroup", code: result)
        }

        // Establish a distinct group atomically as part of spawn. A parent-side
        // setpgid after launch races the child exec and cannot secure cancellation.
        var spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
            | Int16(POSIX_SPAWN_SETSIGDEF)
            | Int16(POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
            spawnFlags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        result = posix_spawnattr_setflags(&attributes, spawnFlags)
        guard result == 0 else {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw posixError(operation: "posix_spawnattr_setflags", code: result)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
        for argument in arguments {
            argv.append(strdup(argument))
        }
        argv.append(nil)
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        var envp: [UnsafeMutablePointer<CChar>?] = []
        envp.reserveCapacity(environment.count + 1)
        for (key, value) in environment {
            envp.append(strdup("\(key)=\(value)"))
        }
        envp.append(nil)
        defer {
            for pointer in envp where pointer != nil {
                free(pointer)
            }
        }

        var pid: pid_t = 0
        result = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        guard result == 0 else {
            closePipe(&outputPipe)
            closePipe(&inputPipe)
            throw posixError(operation: "posix_spawn(\(executable))", code: result)
        }

        systemClose(outputPipe[1])
        outputPipe[1] = -1
        if hasInput {
            systemClose(inputPipe[0])
            inputPipe[0] = -1
        }
        let outputHandle = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
        outputPipe[0] = -1
        let inputHandle: FileHandle?
        if hasInput {
            inputHandle = FileHandle(fileDescriptor: inputPipe[1], closeOnDealloc: true)
            inputPipe[1] = -1
        } else {
            inputHandle = nil
        }
        return SpawnedProcess(pid: pid, output: outputHandle, input: inputHandle)
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags: Int32
        #if canImport(Darwin)
            flags = Darwin.fcntl(descriptor, F_GETFD)
        #else
            flags = Glibc.fcntl(descriptor, F_GETFD)
        #endif
        guard flags >= 0 else { throw posixError(operation: "fcntl(F_GETFD)", code: errno) }
        let result: Int32
        #if canImport(Darwin)
            result = Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
        #else
            result = Glibc.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
        #endif
        guard result == 0 else { throw posixError(operation: "fcntl(F_SETFD)", code: errno) }
    }

    private static func relocatePipeDescriptors(_ descriptors: inout [Int32]) throws {
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let original = descriptors[index]
            let relocated: Int32
            #if canImport(Darwin)
                relocated = Darwin.fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            #else
                relocated = Glibc.fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            #endif
            guard relocated >= 0 else {
                throw posixError(operation: "fcntl(F_DUPFD_CLOEXEC)", code: errno)
            }
            systemClose(original)
            descriptors[index] = relocated
        }
    }

    private static func closePipe(_ descriptors: inout [Int32]) {
        for index in descriptors.indices where descriptors[index] >= 0 {
            systemClose(descriptors[index])
            descriptors[index] = -1
        }
    }

    @discardableResult
    private static func systemPipe(_ descriptors: inout [Int32]) -> Int32 {
        #if canImport(Darwin)
            Darwin.pipe(&descriptors)
        #else
            Glibc.pipe(&descriptors)
        #endif
    }

    private static func systemClose(_ descriptor: Int32) {
        #if canImport(Darwin)
            _ = Darwin.close(descriptor)
        #else
            _ = Glibc.close(descriptor)
        #endif
    }

    private static func posixError(operation: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}
