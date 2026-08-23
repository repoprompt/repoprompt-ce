import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptShared
import RepoPromptWorkspaceRuntimeCore

public actor WorkflowRepository {
    private static let maximumCustomWorkflows = 200
    private static let maximumDefinitionBytes = 256 * 1024
    private let store: any WorkflowRepositoryStore
    private let catalog: BuiltinWorkflowCatalog
    private let now: @Sendable () -> Date

    public init(
        store: any WorkflowRepositoryStore,
        catalog: BuiltinWorkflowCatalog = BuiltinWorkflowCatalog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.catalog = catalog
        self.now = now
    }

    public func recover() async throws {
        let builtins = try catalog.workflows()
        try await store.installWorkflows(builtins)
        try await store.bootstrapWorkflowRepository(builtins: builtins, now: now())
        _ = try await validateSnapshot(store.workflowRepositorySnapshot(), canonicalBuiltins: builtins)
    }

    public func snapshot() async throws -> ServerWorkflowRepositorySnapshot {
        try await store.workflowRepositorySnapshot()
    }

    public func discoveryWorkflows() async throws -> [WorkflowSnapshot] {
        let repository = try await snapshot()
        return repository.workflows
            .filter { $0.enabled && $0.visible }
            .map { runtimeSnapshot($0, includeSessionCleanupGuidance: repository.includeSessionCleanupGuidance) }
    }

    public func workflow(workflowID: String) async throws -> WorkflowSnapshot {
        let repository = try await snapshot()
        guard let workflow = repository.workflows.first(where: { $0.workflowID == workflowID }),
              workflow.enabled
        else {
            throw ServiceAPIError(code: .notFound, message: "Workflow not found")
        }
        return runtimeSnapshot(workflow, includeSessionCleanupGuidance: repository.includeSessionCleanupGuidance)
    }

    public func create(
        _ request: CreateServerWorkflowRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await fencedSnapshot(expectedRevision: request.expectedRevision)
        guard current.workflows.count(where: { $0.source == .custom }) < Self.maximumCustomWorkflows else {
            throw ServiceAPIError(code: .invalidRequest, message: "Custom workflow limit reached")
        }
        let normalized = try normalizeCustom(name: request.name, definition: request.definition)
        try ensureUniqueName(normalized.name, excluding: nil, workflows: current.workflows)
        let featuredOrder = request.featured ? current.workflows.compactMap(\.featuredOrder).count : nil
        let workflow = ServerWorkflowDefinition(
            workflowID: "custom-\(UUID().uuidString.lowercased())",
            source: .custom,
            name: normalized.name,
            definition: normalized.definition,
            contentDigest: digest(normalized.definition),
            enabled: request.enabled,
            visible: true,
            featuredOrder: featuredOrder,
            rowRevision: 1
        )
        return try await persist(
            current: current,
            workflows: current.workflows + [workflow],
            includeCleanup: current.includeSessionCleanupGuidance,
            operation: "create",
            attribution: attribution
        )
    }

    public func update(
        workflowID: String,
        request: UpdateServerWorkflowRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await fencedSnapshot(expectedRevision: request.expectedRevision)
        guard let existing = current.workflows.first(where: { $0.workflowID == workflowID }) else {
            throw ServiceAPIError(code: .notFound, message: "Workflow not found")
        }
        guard existing.source == .custom else {
            throw ServiceAPIError(code: .invalidRequest, message: "Built-in workflows cannot be overwritten")
        }
        try fenceRow(existing, expected: request.expectedRowRevision)
        let normalized = try normalizeCustom(name: request.name, definition: request.definition)
        try ensureUniqueName(normalized.name, excluding: workflowID, workflows: current.workflows)
        let featuredOrder = request.featured
            ? (existing.featuredOrder ?? current.workflows.compactMap(\.featuredOrder).count)
            : nil
        let updated = ServerWorkflowDefinition(
            workflowID: existing.workflowID,
            source: .custom,
            name: normalized.name,
            definition: normalized.definition,
            contentDigest: digest(normalized.definition),
            enabled: request.enabled,
            visible: true,
            featuredOrder: featuredOrder,
            rowRevision: existing.rowRevision + 1
        )
        return try await persist(
            current: current,
            workflows: replacing(existing.workflowID, with: updated, in: current.workflows),
            includeCleanup: current.includeSessionCleanupGuidance,
            operation: "update",
            attribution: attribution
        )
    }

    public func clone(
        workflowID: String,
        request: CloneServerWorkflowRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await fencedSnapshot(expectedRevision: request.expectedRevision)
        guard current.workflows.count(where: { $0.source == .custom }) < Self.maximumCustomWorkflows,
              let source = current.workflows.first(where: { $0.workflowID == workflowID })
        else {
            throw ServiceAPIError(code: .notFound, message: "Workflow not found or custom workflow limit reached")
        }
        try fenceRow(source, expected: request.expectedSourceRowRevision)
        let normalized = try normalizeCustom(name: request.name, definition: source.definition)
        try ensureUniqueName(normalized.name, excluding: nil, workflows: current.workflows)
        let clone = ServerWorkflowDefinition(
            workflowID: "custom-\(UUID().uuidString.lowercased())",
            source: .custom,
            name: normalized.name,
            definition: normalized.definition,
            contentDigest: digest(normalized.definition),
            enabled: true,
            visible: true,
            rowRevision: 1
        )
        return try await persist(
            current: current,
            workflows: current.workflows + [clone],
            includeCleanup: current.includeSessionCleanupGuidance,
            operation: "clone",
            attribution: attribution
        )
    }

    public func delete(
        workflowID: String,
        request: DeleteServerWorkflowRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await fencedSnapshot(expectedRevision: request.expectedRevision)
        guard let existing = current.workflows.first(where: { $0.workflowID == workflowID }) else {
            throw ServiceAPIError(code: .notFound, message: "Workflow not found")
        }
        guard existing.source == .custom else {
            throw ServiceAPIError(code: .invalidRequest, message: "Built-in workflows cannot be deleted")
        }
        try fenceRow(existing, expected: request.expectedRowRevision)
        return try await persist(
            current: current,
            workflows: current.workflows.filter { $0.workflowID != workflowID },
            includeCleanup: current.includeSessionCleanupGuidance,
            operation: "delete",
            attribution: attribution
        )
    }

    public func setVisibility(
        workflowID: String,
        request: SetServerWorkflowVisibilityRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await fencedSnapshot(expectedRevision: request.expectedRevision)
        guard let existing = current.workflows.first(where: { $0.workflowID == workflowID }) else {
            throw ServiceAPIError(code: .notFound, message: "Workflow not found")
        }
        guard existing.source == .builtin else {
            throw ServiceAPIError(code: .invalidRequest, message: "Only built-in workflows can be hidden")
        }
        try fenceRow(existing, expected: request.expectedRowRevision)
        let updated = ServerWorkflowDefinition(
            workflowID: existing.workflowID,
            source: existing.source,
            name: existing.name,
            definition: existing.definition,
            contentDigest: existing.contentDigest,
            enabled: existing.enabled,
            visible: request.visible,
            featuredOrder: request.visible ? existing.featuredOrder : nil,
            rowRevision: existing.rowRevision + 1
        )
        return try await persist(
            current: current,
            workflows: replacing(existing.workflowID, with: updated, in: current.workflows),
            includeCleanup: current.includeSessionCleanupGuidance,
            operation: "setVisibility",
            attribution: attribution
        )
    }

    public func reorder(
        _ request: ReorderServerWorkflowsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await fencedSnapshot(expectedRevision: request.expectedRevision)
        guard Set(request.featuredWorkflowIDs).count == request.featuredWorkflowIDs.count,
              request.featuredWorkflowIDs.allSatisfy({ id in
                  current.workflows.contains { $0.workflowID == id && $0.visible }
              })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Featured workflow order is invalid")
        }
        let order = Dictionary(uniqueKeysWithValues: request.featuredWorkflowIDs.enumerated().map { ($0.element, $0.offset) })
        let updated = current.workflows.map { workflow in
            let nextOrder = order[workflow.workflowID]
            guard nextOrder != workflow.featuredOrder else { return workflow }
            return ServerWorkflowDefinition(
                workflowID: workflow.workflowID,
                source: workflow.source,
                name: workflow.name,
                definition: workflow.definition,
                contentDigest: workflow.contentDigest,
                enabled: workflow.enabled,
                visible: workflow.visible,
                featuredOrder: nextOrder,
                rowRevision: workflow.rowRevision + 1
            )
        }
        return try await persist(
            current: current,
            workflows: updated,
            includeCleanup: current.includeSessionCleanupGuidance,
            operation: "reorder",
            attribution: attribution
        )
    }

    public func updatePreferences(
        _ request: UpdateServerWorkflowPreferencesRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let payload = try JSONEncoder.serviceEncoder.encode(request)
        return try await store.replaceWorkflowCleanupGuidance(
            request.includeSessionCleanupGuidance,
            audit: .init(
                operation: "updatePreferences",
                attribution: attribution,
                payloadDigest: PortableContentDigest.sha256Hex(payload)
            )
        )
    }

    public func reload(
        _ request: ReloadServerWorkflowsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await fencedSnapshot(expectedRevision: request.expectedRevision)
        let canonical = try catalog.workflows()
        let canonicalByID = Dictionary(uniqueKeysWithValues: canonical.map { ($0.workflowID, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.workflows.map { ($0.workflowID, $0) })
        var reloaded = canonical.map { workflow -> ServerWorkflowDefinition in
            let existing = currentByID[workflow.workflowID]
            let changed = existing?.contentDigest != workflow.contentDigest || existing?.name != workflow.name
            return ServerWorkflowDefinition(
                workflowID: workflow.workflowID,
                source: .builtin,
                name: workflow.name,
                definition: workflow.definition,
                contentDigest: workflow.contentDigest,
                enabled: true,
                visible: existing?.visible ?? (workflow.workflowID != WorkflowRepositoryDefaults.hiddenBuiltInID),
                featuredOrder: existing?.featuredOrder,
                rowRevision: changed ? (existing?.rowRevision ?? 0) + 1 : existing?.rowRevision ?? 1
            )
        }
        for custom in current.workflows where custom.source == .custom {
            let normalized = try normalizeCustom(name: custom.name, definition: custom.definition)
            guard canonicalByID[custom.workflowID] == nil else {
                throw ServiceAPIError(code: .invalidRequest, message: "Custom workflow ID collides with a built-in")
            }
            reloaded.append(ServerWorkflowDefinition(
                workflowID: custom.workflowID,
                source: .custom,
                name: normalized.name,
                definition: normalized.definition,
                contentDigest: digest(normalized.definition),
                enabled: custom.enabled,
                visible: custom.visible,
                featuredOrder: custom.featuredOrder,
                rowRevision: custom.rowRevision
            ))
        }
        _ = try validateSnapshot(
            .init(workflows: reloaded, includeSessionCleanupGuidance: current.includeSessionCleanupGuidance, revision: current.revision, updatedAt: current.updatedAt),
            canonicalBuiltins: canonical
        )
        return try await persist(
            current: current,
            workflows: reloaded,
            includeCleanup: current.includeSessionCleanupGuidance,
            operation: "reload",
            attribution: attribution
        )
    }

    public func wrapUserText(workflowID: String, userText: String) async throws -> String {
        let repository = try await snapshot()
        guard let workflow = repository.workflows.first(where: { $0.workflowID == workflowID }),
              workflow.enabled
        else {
            throw ServiceAPIError(code: .notFound, message: "Workflow not found")
        }
        return WorkflowCatalogConsume.wrap(
            template: workflow.definition,
            userText: userText,
            source: workflow.source,
            includeBuiltinCleanup: repository.includeSessionCleanupGuidance
        )
    }
}

public enum WorkflowCatalogConsume {
    public static let builtinCleanupGuidance = """

    ---
    ### Session cleanup guidance
    After recording completed delegated work, remove disposable finished agent sessions with the authenticated session-cleanup operation. Never remove active, blocked, or still-needed sessions.
    """

    public static func stripYAMLFrontmatter(_ text: String) -> String {
        var body = text
        if body.hasPrefix("---") {
            let searchRange = body.index(body.startIndex, offsetBy: 3) ..< body.endIndex
            if let closingRange = body.range(of: "\n---", range: searchRange) {
                body = String(body[closingRange.upperBound...])
                    .trimmingCharacters(in: .newlines)
            }
        }
        return body
    }

    public static func wrap(
        template: String,
        userText: String,
        source: ServerWorkflowSource,
        includeBuiltinCleanup: Bool
    ) -> String {
        var body = stripYAMLFrontmatter(template).replacingOccurrences(of: "$ARGUMENTS", with: userText)
        if includeBuiltinCleanup, source == .builtin {
            body += builtinCleanupGuidance
        }
        return body
    }

    public static func renderedDefinition(
        _ definition: String,
        source: ServerWorkflowSource,
        includeBuiltinCleanup: Bool
    ) -> String {
        guard includeBuiltinCleanup, source == .builtin else { return definition }
        return definition + builtinCleanupGuidance
    }
}

private extension WorkflowRepository {
    func runtimeSnapshot(_ workflow: ServerWorkflowDefinition, includeSessionCleanupGuidance: Bool) -> WorkflowSnapshot {
        let definition = WorkflowCatalogConsume.renderedDefinition(
            workflow.definition,
            source: workflow.source,
            includeBuiltinCleanup: includeSessionCleanupGuidance
        )
        return WorkflowSnapshot(
            workflowID: workflow.workflowID,
            source: workflow.source.rawValue,
            name: workflow.name,
            definition: definition,
            contentDigest: digest(definition),
            enabled: workflow.enabled,
            visible: workflow.visible,
            featuredOrder: workflow.featuredOrder,
            rowRevision: workflow.rowRevision
        )
    }

    func fencedSnapshot(expectedRevision: Int64) async throws -> ServerWorkflowRepositorySnapshot {
        let current = try await snapshot()
        guard current.revision == expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Workflow repository revision is stale", currentRevision: current.revision)
        }
        return current
    }

    func fenceRow(_ workflow: ServerWorkflowDefinition, expected: Int64) throws {
        guard workflow.rowRevision == expected else {
            throw ServiceAPIError(code: .staleRevision, message: "Workflow row revision is stale", currentRevision: workflow.rowRevision)
        }
    }

    func persist(
        current: ServerWorkflowRepositorySnapshot,
        workflows: [ServerWorkflowDefinition],
        includeCleanup: Bool,
        operation: String,
        attribution: SettingsMutationAttribution
    ) async throws -> ServerWorkflowRepositorySnapshot {
        let canonical = try catalog.workflows()
        let candidate = ServerWorkflowRepositorySnapshot(
            workflows: normalizeFeaturedOrder(workflows),
            includeSessionCleanupGuidance: includeCleanup,
            revision: current.revision + 1,
            updatedAt: now()
        )
        _ = try validateSnapshot(candidate, canonicalBuiltins: canonical)
        let payload = try JSONEncoder.serviceEncoder.encode(candidate)
        return try await store.replaceWorkflowRepositorySnapshot(
            candidate,
            expectedRevision: current.revision,
            audit: .init(
                operation: operation,
                attribution: attribution,
                payloadDigest: PortableContentDigest.sha256Hex(payload)
            )
        )
    }

    func validateSnapshot(
        _ snapshot: ServerWorkflowRepositorySnapshot,
        canonicalBuiltins: [WorkflowSnapshot]
    ) throws -> ServerWorkflowRepositorySnapshot {
        guard snapshot.workflows.count <= canonicalBuiltins.count + Self.maximumCustomWorkflows,
              Set(snapshot.workflows.map(\.workflowID)).count == snapshot.workflows.count,
              snapshot.workflows.allSatisfy({ $0.rowRevision >= 1 })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Workflow repository collection is invalid")
        }
        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalBuiltins.map { ($0.workflowID, $0) })
        var names = Set<String>()
        for workflow in snapshot.workflows {
            guard names.insert(folded(workflow.name)).inserted else {
                throw ServiceAPIError(code: .invalidRequest, message: "Workflow names must be unique")
            }
            switch workflow.source {
            case .builtin:
                guard let canonical = canonicalByID[workflow.workflowID],
                      canonical.name == workflow.name,
                      canonical.definition == workflow.definition,
                      canonical.contentDigest == workflow.contentDigest,
                      workflow.enabled
                else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Built-in workflow content is immutable")
                }
            case .custom:
                let normalized = try normalizeCustom(name: workflow.name, definition: workflow.definition)
                guard normalized.name == workflow.name,
                      normalized.definition == workflow.definition,
                      digest(workflow.definition) == workflow.contentDigest,
                      workflow.workflowID.hasPrefix("custom-")
                else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Custom workflow definition is invalid")
                }
            }
        }
        guard canonicalByID.keys.allSatisfy({ id in snapshot.workflows.contains { $0.workflowID == id && $0.source == .builtin } }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Built-in workflow catalog is incomplete")
        }
        let featured = snapshot.workflows.compactMap(\.featuredOrder).sorted()
        guard featured == Array(0 ..< featured.count) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Featured workflow order is invalid")
        }
        return snapshot
    }

    func normalizeCustom(name: String, definition: String) throws -> (name: String, definition: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDefinition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= 128,
              !normalizedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(normalizedName),
              !normalizedDefinition.isEmpty,
              normalizedDefinition.utf8.count <= Self.maximumDefinitionBytes,
              !normalizedDefinition.unicodeScalars.contains("\0"),
              !ProviderSecretRedaction.containsLikelySecret(normalizedDefinition)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Workflow name or markdown is invalid")
        }
        try validateMarkdownDefinition(normalizedDefinition)
        return (normalizedName, normalizedDefinition)
    }

    func validateMarkdownDefinition(_ definition: String) throws {
        guard definition.hasPrefix("---\n"),
              let closing = definition.range(of: "\n---\n", range: definition.index(definition.startIndex, offsetBy: 4) ..< definition.endIndex)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Workflow markdown requires YAML frontmatter")
        }
        let frontmatter = definition[definition.index(definition.startIndex, offsetBy: 4) ..< closing.lowerBound]
        let body = definition[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        var keys = Set<String>()
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: ":") else {
                throw ServiceAPIError(code: .invalidRequest, message: "Workflow frontmatter is malformed")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  keys.insert(key).inserted,
                  !["path", "url", "include", "external_file", "external-file"].contains(key)
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "Workflow frontmatter contains an unsupported field")
            }
        }
        guard keys.contains("name"), keys.contains("description"), !body.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Workflow markdown is missing required content")
        }
    }

    func ensureUniqueName(_ name: String, excluding workflowID: String?, workflows: [ServerWorkflowDefinition]) throws {
        guard !workflows.contains(where: { $0.workflowID != workflowID && folded($0.name) == folded(name) }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Workflow name already exists")
        }
    }

    func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func digest(_ definition: String) -> String {
        PortableContentDigest.sha256Hex(Data(definition.utf8))
    }

    func replacing(_ workflowID: String, with replacement: ServerWorkflowDefinition, in workflows: [ServerWorkflowDefinition]) -> [ServerWorkflowDefinition] {
        workflows.map { $0.workflowID == workflowID ? replacement : $0 }
    }

    func normalizeFeaturedOrder(_ workflows: [ServerWorkflowDefinition]) -> [ServerWorkflowDefinition] {
        let orderedFeatured = workflows
            .filter { $0.featuredOrder != nil }
            .sorted { ($0.featuredOrder ?? .max, $0.workflowID) < ($1.featuredOrder ?? .max, $1.workflowID) }
        let order = Dictionary(uniqueKeysWithValues: orderedFeatured.enumerated().map { ($0.element.workflowID, $0.offset) })
        return workflows.map { workflow in
            guard workflow.featuredOrder != order[workflow.workflowID] else { return workflow }
            return ServerWorkflowDefinition(
                workflowID: workflow.workflowID,
                source: workflow.source,
                name: workflow.name,
                definition: workflow.definition,
                contentDigest: workflow.contentDigest,
                enabled: workflow.enabled,
                visible: workflow.visible,
                featuredOrder: order[workflow.workflowID],
                rowRevision: workflow.rowRevision + 1
            )
        }
    }
}
