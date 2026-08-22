import Foundation
import MCP
import RepoPromptDomainRuntime

private extension DomainSettingValue {
    init(mcpValue: Value) throws {
        switch mcpValue {
        case let .bool(value): self = .bool(value)
        case let .int(value): self = .integer(value)
        case let .double(value): self = .number(value)
        case let .string(value): self = .string(value)
        case .null: self = .null
        default: throw MCPError.invalidParams("setting value must be a boolean, integer, number, string, or null")
        }
    }

    var mcpValue: Value {
        switch self {
        case let .bool(value): .bool(value)
        case let .integer(value): .int(value)
        case let .number(value): .double(value)
        case let .string(value): .string(value)
        case .null: .null
        }
    }
}

actor DirectHeadlessGlobalBackend: DomainGlobalControlBackend {
    private let runtime: MCPDomainRuntime
    private let scopeID: DomainStandaloneScopeID
    private let context: DirectHeadlessDomainContext
    private let settingsStore: DomainDirectSettingsStore

    init(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        context: DirectHeadlessDomainContext,
        settingsStore: DomainDirectSettingsStore? = nil
    ) {
        self.runtime = runtime
        self.scopeID = scopeID
        self.context = context
        self.settingsStore = settingsStore ?? DomainDirectSettingsStore(
            persistence: runtime.persistenceCoordinator,
            profileIdentifier: runtime.configuration.profileIdentifier
        )
    }

    func accessSettings(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        await settingsStore.bootstrap()
        let args = try request.mcpArguments()
        let op = args["op"]?.stringValue ?? "list"
        switch op {
        case "list":
            let descriptors = try DomainAppSettingsCatalog.descriptors(in: args["group"]?.stringValue)
            let values = await settingsStore.effectiveValues(for: descriptors)
            let detailed = args["detailed"]?.boolValue == true
            let catalog = descriptors.map { descriptor in
                var item: [String: Value] = [
                    "key": .string(descriptor.key),
                    "group": .string(descriptor.group),
                    "type": .string(descriptor.valueKind.rawValue),
                    "value": values[descriptor.key]?.mcpValue ?? .null,
                    "writable": .bool(true)
                ]
                if descriptor.optionsAvailable { item["options_available"] = .bool(true) }
                if detailed { item["description"] = .string(descriptor.description) }
                return Value.object(item)
            }
            return try .object([
                "settings": .array(catalog),
                "profile": .string(runtime.configuration.profileIdentifier),
                "backend": .string("headless")
            ])
        case "get":
            let selectors = [args["key"] != nil, args["keys"] != nil, args["group"] != nil].count(where: { $0 })
            guard selectors == 1 else { throw MCPError.invalidParams("get requires exactly one of key, keys, or group") }
            if let key = args["key"]?.stringValue {
                return try await .object(["key": .string(key), "value": settingsStore.effectiveValue(for: key).mcpValue])
            }
            let descriptors: [DomainSettingDescriptor] = if let keys = args["keys"]?.arrayValue?.compactMap(\.stringValue) {
                try keys.map { key in
                    guard let descriptor = DomainAppSettingsCatalog.descriptor(for: key) else {
                        throw DomainDirectSettingsError.unknownKey(key)
                    }
                    return descriptor
                }
            } else {
                try DomainAppSettingsCatalog.descriptors(in: args["group"]?.stringValue)
            }
            let values = await settingsStore.effectiveValues(for: descriptors)
            return try .object(["values": .object(values.mapValues(\.mcpValue))])
        case "set":
            guard let key = args["key"]?.stringValue, let value = args["value"] else {
                throw MCPError.invalidParams("set requires key and value")
            }
            let domainValue = try DomainSettingValue(mcpValue: value)
            let revision = try await settingsStore.set(key: key, value: domainValue)
            return try await .object([
                "key": .string(key),
                "value": settingsStore.effectiveValue(for: key).mcpValue,
                "applied": .bool(true),
                "revision": .int(Int(revision))
            ])
        case "options":
            guard let key = args["key"]?.stringValue,
                  let descriptor = DomainAppSettingsCatalog.descriptor(for: key),
                  descriptor.optionsAvailable
            else {
                throw MCPError.invalidParams("options requires a key with options_available=true")
            }
            let limit = max(1, min(args["limit"]?.intValue ?? 200, 200))
            let options = (descriptor.allowedValues ?? []).prefix(limit).map { value in
                Value.object(["value": value.mcpValue])
            }
            return try .object(["key": .string(key), "options": .array(Array(options))])
        default:
            throw MCPError.invalidParams("unknown app_settings op: \(op)")
        }
    }

    func routeContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        if args["window_id"] != nil {
            throw MCPError.invalidParams("window_id is unavailable with --backend headless; bind a context_id or working_dirs")
        }
        let op = args["op"]?.stringValue ?? "list"
        switch op {
        case "list":
            return try await workspaceCatalogResult(includeBinding: true)
        case "status":
            let snapshot = try await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
            return try .object(["binding": bindingValue(snapshot.binding), "backend": .string("headless")])
        case "bind":
            let identity: DomainContextIdentity
            if let raw = args["context_id"]?.stringValue, let contextID = UUID(uuidString: raw) {
                let catalog = await runtime.workspaceStore.snapshot()
                let matches = catalog.workspaces.flatMap(\.contexts).filter {
                    $0.metadata.identity.contextID == contextID
                }
                guard matches.count == 1, let match = matches.first else {
                    throw MCPError.invalidParams("context_id is unknown or ambiguous")
                }
                identity = match.metadata.identity
            } else if args["working_dirs"] != nil {
                let workingDirs = try Self.workingDirectories(from: args["working_dirs"])
                let requested = Set(workingDirs.map(\.path))
                let catalog = await runtime.workspaceStore.snapshot()
                let workspace = try Self.resolveWorkingDirectoryWorkspace(
                    requestedRoots: requested,
                    catalog: catalog
                )
                let activeID = workspace.document.metadata.activeContextID
                guard let chosen = workspace.contexts.first(where: { $0.metadata.identity.contextID == activeID })
                    ?? (workspace.contexts.count == 1 ? workspace.contexts.first : nil)
                else {
                    throw MCPError.invalidParams("workspace does not have one unambiguous context")
                }
                identity = chosen.metadata.identity
            } else {
                throw MCPError.invalidParams("headless bind requires context_id or working_dirs")
            }
            try await context.validateBinding(identity)
            let snapshot = try await runtime.standaloneScopeCoordinator.bind(scopeID: scopeID, context: identity)
            return try .object(["binding": bindingValue(snapshot.binding), "backend": .string("headless")])
        default:
            throw MCPError.invalidParams("unknown bind_context op: \(op)")
        }
    }

    func manageWorkspaceLifecycle(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        if args["window_id"] != nil || args["open_in_new_window"]?.boolValue == true {
            throw MCPError.invalidParams("window selectors and new-window presentation are unavailable with --backend headless")
        }
        let action = args["action"]?.stringValue ?? "list"
        switch action {
        case "list":
            return try await workspaceCatalogResult(includeBinding: false)
        case "switch":
            guard let selector = args["workspace"]?.stringValue else {
                throw MCPError.invalidParams("switch requires workspace")
            }
            let catalog = await runtime.workspaceStore.snapshot()
            let matches = catalog.workspaces.filter {
                $0.document.workspaceID.uuidString == selector
                    || $0.document.metadata.name.localizedCaseInsensitiveCompare(selector) == .orderedSame
            }
            guard matches.count == 1, let workspace = matches.first else {
                throw MCPError.invalidParams("workspace is unknown or ambiguous")
            }
            let activeID = workspace.document.metadata.activeContextID
            guard let chosen = workspace.contexts.first(where: { $0.metadata.identity.contextID == activeID })
                ?? workspace.contexts.first
            else {
                throw MCPError.invalidParams("workspace has no contexts")
            }
            try await context.validateBinding(chosen.metadata.identity)
            let snapshot = try await runtime.standaloneScopeCoordinator.bind(
                scopeID: scopeID,
                context: chosen.metadata.identity
            )
            return try .object([
                "workspace_id": .string(workspace.document.workspaceID.uuidString),
                "context_id": .string(chosen.metadata.identity.contextID.uuidString),
                "binding": bindingValue(snapshot.binding)
            ])
        case "list_tabs":
            return try await workspaceCatalogResult(includeBinding: true)
        case "select_tab":
            guard let raw = args["tab"]?.stringValue, let contextID = UUID(uuidString: raw) else {
                throw MCPError.invalidParams("headless select_tab requires a canonical tab UUID")
            }
            let forwarded = try DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode(["op": Value.string("bind"), "context_id": .string(contextID.uuidString)]),
                securityContext: request.securityContext
            )
            return try await routeContext(forwarded)
        case "create", "hide", "unhide", "delete", "add_folder", "remove_folder", "create_tab", "close_tab":
            return try await mutateWorkspaceLifecycle(action: action, args: args, request: request)
        default:
            throw MCPError.invalidParams("unknown manage_workspaces action: \(action)")
        }
    }

    private func mutateWorkspaceLifecycle(
        action: String,
        args: [String: Value],
        request: DomainPhysicalToolRequest
    ) async throws -> DomainPhysicalToolResult {
        let operationID = request.securityContext?.invocationID ?? UUID()
        if action == "create" {
            guard let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw MCPError.invalidParams("create requires a non-empty name")
            }
            let roots: [String] = if let rawPath = args["folder_path"]?.stringValue {
                try [validatedDirectory(rawPath).path]
            } else {
                []
            }
            let catalog = await runtime.workspaceStore.snapshot()
            let workspaceID = UUID()
            let contextID = UUID()
            let object: [String: Any] = [
                "id": workspaceID.uuidString,
                "schemaVersion": 1,
                "name": name,
                "repoPaths": roots,
                "isSystemWorkspace": false,
                "isHiddenInMenus": false,
                "activeComposeTabID": contextID.uuidString,
                "composeTabs": [[
                    "id": contextID.uuidString,
                    "name": "Prompt 1",
                    "prompt": "",
                    "selectedPaths": []
                ]]
            ]
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let fileURL = runtime.configuration.workspaceStorageDirectory
                .appendingPathComponent("\(workspaceID.uuidString).json", isDirectory: false)
            let document = try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
            try await context.validateWorkspaceRoots(document.metadata.repoPaths)
            try await MCPDomainMutationCommitContext.willCommit()
            let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: catalog.catalogRevision,
                origin: .standalone,
                command: .createWorkspace(document)
            ))
            try requireApplied(outcome)
            var result: [String: Value] = [
                "workspace_id": .string(workspaceID.uuidString),
                "context_id": .string(contextID.uuidString),
                "name": .string(name),
                "catalog_revision": .int(Int(outcome.catalogRevision))
            ]
            if args["switch_to_created"]?.boolValue == true {
                let binding = try await runtime.standaloneScopeCoordinator.bind(
                    scopeID: scopeID,
                    context: DomainContextIdentity(workspaceID: workspaceID, contextID: contextID)
                )
                result["binding"] = bindingValue(binding.binding)
            }
            return try .object(result)
        }

        let catalog = await runtime.workspaceStore.snapshot()
        let workspace: DomainWorkspaceSnapshot
        if let selector = args["workspace"]?.stringValue {
            workspace = try resolveWorkspace(selector, in: catalog, includeHidden: args["include_hidden"]?.boolValue == true)
        } else {
            let current = try await context.snapshot(for: request)
            workspace = current.workspace
        }

        if action == "delete" {
            try await MCPDomainMutationCommitContext.willCommit()
            let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: catalog.catalogRevision,
                expectedWorkspaceRevision: workspace.revisions.workingRevision,
                origin: .standalone,
                command: .deleteWorkspace(workspaceID: workspace.document.workspaceID)
            ))
            try requireApplied(outcome)
            if let scope = try? await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID),
               bindingContext(scope.binding)?.workspaceID == workspace.document.workspaceID
            {
                _ = try? await runtime.standaloneScopeCoordinator.unbind(scopeID: scopeID)
            }
            return try .object([
                "workspace_id": .string(workspace.document.workspaceID.uuidString),
                "deleted": .bool(true),
                "catalog_revision": .int(Int(outcome.catalogRevision))
            ])
        }

        guard var object = try JSONSerialization.jsonObject(with: workspace.document.documentBytes) as? [String: Any] else {
            throw DirectHeadlessDomainContext.Error.invalidWorkspaceDocument
        }
        var selectedContextID: UUID?
        var closedContextID: UUID?
        var expectedClosedBinding: DomainBinding?
        switch action {
        case "hide", "unhide":
            object["isHiddenInMenus"] = action == "hide"
        case "add_folder", "remove_folder":
            guard let rawPath = args["folder_path"]?.stringValue else {
                throw MCPError.invalidParams("\(action) requires folder_path")
            }
            let path = try validatedDirectory(rawPath).path
            var roots = object["repoPaths"] as? [String] ?? []
            if action == "add_folder" {
                if !roots.contains(path) { roots.append(path) }
            } else {
                roots.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == path }
            }
            object["repoPaths"] = roots
        case "create_tab":
            var tabs = object["composeTabs"] as? [[String: Any]] ?? []
            let newID = UUID()
            let mode = args["mode"]?.stringValue ?? "blank"
            var tab: [String: Any]
            if mode == "fork" {
                guard let source = resolveContext(args["source_tab"]?.stringValue, in: tabs) else {
                    throw MCPError.invalidParams("create_tab mode=fork requires an unambiguous source_tab")
                }
                tab = source
            } else if mode == "blank" {
                tab = ["prompt": "", "selectedPaths": []]
            } else {
                throw MCPError.invalidParams("create_tab mode must be blank or fork")
            }
            tab["id"] = newID.uuidString
            tab["name"] = args["name"]?.stringValue ?? "Prompt \(tabs.count + 1)"
            tabs.append(tab)
            object["composeTabs"] = tabs
            if args["bind"]?.boolValue != false {
                selectedContextID = newID
                object["activeComposeTabID"] = newID.uuidString
            }
        case "close_tab":
            guard var tabs = object["composeTabs"] as? [[String: Any]], tabs.count > 1,
                  let target = resolveContext(args["tab"]?.stringValue, in: tabs),
                  let rawID = target["id"] as? String,
                  let targetID = UUID(uuidString: rawID)
            else {
                throw MCPError.invalidParams("close_tab requires an existing tab and refuses to close the last tab")
            }
            closedContextID = targetID
            let activeID = (object["activeComposeTabID"] as? String).flatMap(UUID.init(uuidString:))
            if activeID == targetID, args["allow_active"]?.boolValue != true {
                throw MCPError.invalidRequest("close_tab refuses to close the active tab unless allow_active=true")
            }
            tabs.removeAll { ($0["id"] as? String) == rawID }
            object["composeTabs"] = tabs
            if activeID == targetID, let replacement = tabs.first?["id"] as? String {
                object["activeComposeTabID"] = replacement
                selectedContextID = UUID(uuidString: replacement)
            }
        default:
            throw MCPError.invalidParams("unsupported workspace mutation: \(action)")
        }

        if let closedContextID,
           let scope = try? await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID),
           scope.binding.ordinaryContextMatches(DomainContextIdentity(
               workspaceID: workspace.document.workspaceID,
               contextID: closedContextID
           ))
        {
            expectedClosedBinding = scope.binding
        }

        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let replacement = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: workspace.document.fileURL
        )
        if action == "add_folder" || action == "remove_folder" || selectedContextID != nil {
            try await context.validateWorkspaceRoots(replacement.metadata.repoPaths)
        }
        try await MCPDomainMutationCommitContext.willCommit()
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedCatalogRevision: catalog.catalogRevision,
            expectedWorkspaceRevision: workspace.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(replacement)
        ))
        try requireApplied(outcome)
        var result: [String: Value] = [
            "workspace_id": .string(workspace.document.workspaceID.uuidString),
            "action": .string(action),
            "workspace_revision": .int(Int(outcome.after?.workingRevision ?? workspace.revisions.workingRevision))
        ]
        var repairedBinding: DomainBinding?
        var repairedContextID: UUID?
        if let expectedClosedBinding {
            let casResult: DomainStandaloneBindingCASResult
            if let replacementContextID = replacement.metadata.activeContextID
                ?? replacement.metadata.contexts.first?.identity.contextID
            {
                let bindResult = try await runtime.standaloneScopeCoordinator.compareAndSetBinding(
                    scopeID: scopeID,
                    expectedBinding: expectedClosedBinding,
                    replacement: .context(
                        DomainContextIdentity(
                            workspaceID: workspace.document.workspaceID,
                            contextID: replacementContextID
                        ),
                        explicit: true
                    )
                )
                if bindResult.disposition == .rejected {
                    casResult = try await runtime.standaloneScopeCoordinator.compareAndSetBinding(
                        scopeID: scopeID,
                        expectedBinding: expectedClosedBinding,
                        replacement: .unbound
                    )
                } else {
                    casResult = bindResult
                }
            } else {
                casResult = try await runtime.standaloneScopeCoordinator.compareAndSetBinding(
                    scopeID: scopeID,
                    expectedBinding: expectedClosedBinding,
                    replacement: .unbound
                )
            }
            repairedBinding = casResult.snapshot.binding
            if let repairedBinding,
               case let .context(identity, _) = repairedBinding
            {
                repairedContextID = identity.contextID
            }
        }
        if let repairedBinding {
            result["binding"] = bindingValue(repairedBinding)
            if let repairedContextID {
                result["context_id"] = .string(repairedContextID.uuidString)
            }
        }
        if action == "create_tab", let selectedContextID {
            let binding = try await runtime.standaloneScopeCoordinator.bind(
                scopeID: scopeID,
                context: DomainContextIdentity(
                    workspaceID: workspace.document.workspaceID,
                    contextID: selectedContextID
                )
            )
            result["context_id"] = .string(selectedContextID.uuidString)
            result["binding"] = bindingValue(binding.binding)
        }
        return try .object(result)
    }

    private func resolveWorkspace(
        _ selector: String,
        in catalog: DomainWorkspaceCatalogSnapshot,
        includeHidden: Bool
    ) throws -> DomainWorkspaceSnapshot {
        let matches = catalog.workspaces.filter { workspace in
            let explicitID = workspace.document.workspaceID.uuidString == selector
            let nameMatch = workspace.document.metadata.name.localizedCaseInsensitiveCompare(selector) == .orderedSame
            return explicitID || (nameMatch && (includeHidden || !workspace.document.metadata.isHiddenInMenus))
        }
        guard matches.count == 1, let match = matches.first else {
            throw MCPError.invalidParams("workspace is unknown or ambiguous")
        }
        return match
    }

    private func resolveContext(_ selector: String?, in tabs: [[String: Any]]) -> [String: Any]? {
        guard let selector else { return tabs.count == 1 ? tabs.first : nil }
        let matches = tabs.filter {
            ($0["id"] as? String) == selector
                || (($0["name"] as? String)?.localizedCaseInsensitiveCompare(selector) == .orderedSame)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func validatedDirectory(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MCPError.invalidParams("folder_path must be an existing absolute directory")
        }
        return url
    }

    private func requireApplied(_ outcome: DomainCommandOutcome) throws {
        guard outcome.disposition == .applied
            || outcome.disposition == .unchanged
            || outcome.disposition == .deduplicated
        else {
            throw DirectHeadlessDomainContext.Error.stateConflict(
                outcome.diagnostic ?? outcome.errorCode?.rawValue ?? outcome.disposition.rawValue
            )
        }
    }

    private func workspaceCatalogResult(includeBinding: Bool) async throws -> DomainPhysicalToolResult {
        let catalog = await runtime.workspaceStore.snapshot()
        let workspaces = catalog.workspaces.map { workspace in
            Value.object([
                "workspace_id": .string(workspace.document.workspaceID.uuidString),
                "name": .string(workspace.document.metadata.name),
                "repo_paths": .array(workspace.document.metadata.repoPaths.map(Value.string)),
                "hidden": .bool(workspace.document.metadata.isHiddenInMenus),
                "contexts": .array(workspace.contexts.map { context in
                    .object([
                        "context_id": .string(context.metadata.identity.contextID.uuidString),
                        "name": .string(context.metadata.name)
                    ])
                })
            ])
        }
        var result: [String: Value] = [
            "backend": .string("headless"),
            "workspaces": .array(workspaces),
            "catalog_revision": .int(Int(catalog.catalogRevision))
        ]
        if includeBinding,
           let scope = try? await runtime.standaloneScopeCoordinator.snapshot(scopeID: scopeID)
        {
            result["binding"] = bindingValue(scope.binding)
        }
        return try .object(result)
    }

    nonisolated static func resolveWorkingDirectoryWorkspace(
        requestedRoots: Set<String>,
        catalog: DomainWorkspaceCatalogSnapshot
    ) throws -> DomainWorkspaceSnapshot {
        var exactMatches: [DomainWorkspaceSnapshot] = []
        var supersetMatches: [DomainWorkspaceSnapshot] = []
        for workspace in catalog.workspaces {
            let roots = Set(workspace.document.metadata.repoPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
            })
            if roots == requestedRoots {
                exactMatches.append(workspace)
            } else if roots.isSuperset(of: requestedRoots) {
                supersetMatches.append(workspace)
            }
        }
        let matches = exactMatches.isEmpty ? supersetMatches : exactMatches
        guard matches.count == 1, let workspace = matches.first else {
            throw MCPError.invalidParams("working_dirs did not resolve one existing workspace; direct creation is not implicit")
        }
        return workspace
    }

    nonisolated static func workingDirectories(from value: Value?) throws -> [URL] {
        guard let value else {
            throw MCPError.invalidParams("headless bind requires context_id or working_dirs")
        }
        let values: [String]
        switch value {
        case let .string(raw):
            values = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        case let .array(items):
            values = try items.map { item in
                guard let string = item.stringValue else {
                    throw MCPError.invalidParams("working_dirs must be an array of strings or a comma-separated string")
                }
                return string
            }
        default:
            throw MCPError.invalidParams("working_dirs must be an array of strings or a comma-separated string")
        }

        do {
            return try DirectHeadlessRuntimeLocationResolver.validatedWorkingDirectories(values)
        } catch let error as DomainStandaloneScopeError {
            switch error {
            case let .invalidWorkingDirectory(path):
                throw MCPError.invalidParams(
                    "working_dirs contains invalid directory '\(path)'; expected unique existing absolute directories"
                )
            default:
                throw MCPError.invalidParams("working_dirs is invalid")
            }
        }
    }

    private func bindingContext(_ binding: DomainBinding) -> DomainContextIdentity? {
        switch binding {
        case let .context(identity, _), let .runScoped(_, identity): identity
        case .unbound, .appPresentationWindow: nil
        }
    }

    private func bindingValue(_ binding: DomainBinding) -> Value {
        switch binding {
        case .unbound:
            .object(["kind": .string("unbound")])
        case let .context(identity, explicit):
            .object([
                "kind": .string("context"),
                "workspace_id": .string(identity.workspaceID.uuidString),
                "context_id": .string(identity.contextID.uuidString),
                "explicit": .bool(explicit)
            ])
        case let .runScoped(runID, identity):
            .object([
                "kind": .string("run_scoped"),
                "run_id": .string(runID.uuidString),
                "workspace_id": .string(identity.workspaceID.uuidString),
                "context_id": .string(identity.contextID.uuidString)
            ])
        case .appPresentationWindow:
            .object(["kind": .string("invalid_app_presentation")])
        }
    }
}

actor DirectHeadlessWorkspaceBackend: DomainWorkspaceCapabilityBackend {
    private let service: MCPDomainCanonicalWorkspaceService

    init(context: DirectHeadlessDomainContext) {
        service = MCPDomainCanonicalWorkspaceService(
            adapter: DomainCanonicalWorkspaceAdapter(
                toolSnapshot: { request in
                    try await Self.canonicalSnapshot(context.snapshot(for: request))
                },
                readSnapshot: { request in
                    try await Self.canonicalSnapshot(context.snapshot(for: request))
                },
                mutate: { request, mutation in
                    let updated: DirectHeadlessDomainContext.Snapshot = switch mutation {
                    case let .setPrompt(prompt):
                        try await context.mutate(request: request, mutation: .setPrompt(prompt))
                    case let .setSelection(selection):
                        try await context.mutate(request: request, mutation: .setSelection(selection))
                    }
                    return Self.canonicalSnapshot(updated)
                },
                resolvePath: { rawPath, roots, allowMissingLeaf in
                    try context.resolvePath(rawPath, roots: roots, allowMissingLeaf: allowMissingLeaf)
                }
            )
        )
    }

    func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await service.mutateSelection(request)
    }

    func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await service.inspectCodeStructure(request)
    }

    func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await service.renderFileTree(request)
    }

    func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await service.readFile(request)
    }

    func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await service.searchFiles(request)
    }

    func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await service.renderWorkspaceContext(request)
    }

    func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await service.accessPrompt(request)
    }

    private nonisolated static func canonicalSnapshot(
        _ snapshot: DirectHeadlessDomainContext.Snapshot
    ) -> DomainCanonicalWorkspaceSnapshot {
        DomainCanonicalWorkspaceSnapshot(
            identity: snapshot.identity,
            roots: snapshot.roots,
            prompt: snapshot.prompt,
            selection: snapshot.selection
        )
    }
}
