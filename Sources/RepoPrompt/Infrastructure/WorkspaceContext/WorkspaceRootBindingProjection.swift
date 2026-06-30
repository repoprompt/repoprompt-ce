import Foundation

struct WorkspaceRootBindingProjection: Equatable {
    let sessionID: UUID
    let replacementsByLogicalRootPath: [String: BoundRoot]
    private let visibleLogicalRoots: [WorkspaceRootRef]
    private let lookupPhysicalRootPaths: Set<String>

    struct BoundRoot: Equatable {
        let logicalRoot: WorkspaceRootRef
        let physicalRoot: WorkspaceRootRef
        let binding: AgentSessionWorktreeBinding
        let sessionRootAuthorization: WorkspaceSessionRootAuthorization?

        init(
            logicalRoot: WorkspaceRootRef,
            physicalRoot: WorkspaceRootRef,
            binding: AgentSessionWorktreeBinding,
            sessionRootAuthorization: WorkspaceSessionRootAuthorization? = nil
        ) {
            self.logicalRoot = logicalRoot
            self.physicalRoot = physicalRoot
            self.binding = binding
            self.sessionRootAuthorization = sessionRootAuthorization
        }
    }

    init(
        sessionID: UUID,
        boundRoots: [BoundRoot],
        visibleLogicalRoots: [WorkspaceRootRef] = [],
        lookupPhysicalRootPaths: Set<String>? = nil
    ) {
        self.sessionID = sessionID
        var replacements: [String: BoundRoot] = [:]
        for boundRoot in boundRoots {
            replacements[boundRoot.logicalRoot.standardizedFullPath] = boundRoot
        }
        replacementsByLogicalRootPath = replacements
        self.visibleLogicalRoots = visibleLogicalRoots.isEmpty
            ? boundRoots.map(\.logicalRoot)
            : visibleLogicalRoots
        self.lookupPhysicalRootPaths = lookupPhysicalRootPaths
            ?? Set(boundRoots.map(\.physicalRoot.standardizedFullPath))
    }

    static func logicalAbsolutePath(
        forPhysicalPath rawPath: String,
        binding: AgentSessionWorktreeBinding
    ) -> String? {
        let physicalRoot = StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath)
        let logicalRoot = StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath)
        let physicalPath = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard physicalPath == physicalRoot || physicalPath.hasPrefix(physicalRoot + "/") else { return nil }
        guard physicalPath != physicalRoot else { return logicalRoot }
        let relative = String(physicalPath.dropFirst(physicalRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return StandardizedPath.join(
            standardizedRoot: logicalRoot,
            standardizedRelativePath: relative
        )
    }

    var isEmpty: Bool {
        replacementsByLogicalRootPath.isEmpty
    }

    var logicalRootPaths: Set<String> {
        Set(replacementsByLogicalRootPath.keys)
    }

    var physicalRootPaths: Set<String> {
        Set(replacementsByLogicalRootPath.values.map(\.physicalRoot.standardizedFullPath))
    }

    var canonicalRootPaths: Set<String> {
        Set(visibleLogicalRoots.map(\.standardizedFullPath)).subtracting(logicalRootPaths)
    }

    var lookupRootScope: WorkspaceLookupRootScope {
        .validatedSessionBoundWorkspace(
            canonicalRoots: Set(visibleLogicalRootRefs.filter {
                canonicalRootPaths.contains($0.standardizedFullPath)
            }),
            physicalRoots: Set(physicalRootRefs.filter {
                lookupPhysicalRootPaths.contains($0.standardizedFullPath)
            })
        )
    }

    var isFullyMaterialized: Bool {
        lookupPhysicalRootPaths == physicalRootPaths
    }

    var logicalRootRefs: [WorkspaceRootRef] {
        replacementsByLogicalRootPath.values
            .map(\.logicalRoot)
            .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    var visibleLogicalRootRefs: [WorkspaceRootRef] {
        visibleLogicalRoots.sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    var physicalRootRefs: [WorkspaceRootRef] {
        replacementsByLogicalRootPath.values
            .map(\.physicalRoot)
            .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    var boundRootsForMetadata: [BoundRoot] {
        replacementsByLogicalRootPath.values.sorted { lhs, rhs in
            if lhs.logicalRoot.standardizedFullPath != rhs.logicalRoot.standardizedFullPath {
                return lhs.logicalRoot.standardizedFullPath < rhs.logicalRoot.standardizedFullPath
            }
            if lhs.physicalRoot.standardizedFullPath != rhs.physicalRoot.standardizedFullPath {
                return lhs.physicalRoot.standardizedFullPath < rhs.physicalRoot.standardizedFullPath
            }
            return lhs.binding.worktreeID < rhs.binding.worktreeID
        }
    }

    func translateInputPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawPath }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = expanded.hasPrefix("/") ? StandardizedPath.absolute(expanded) : StandardizedPath.relative(expanded)

        if standardized.hasPrefix("/") {
            if pathIsUnderAnyPhysicalRoot(standardized) {
                return standardized
            }
            if let boundRoot = boundRoot(containingLogicalAbsolutePath: standardized) {
                return replacePrefix(
                    in: standardized,
                    from: boundRoot.logicalRoot.standardizedFullPath,
                    to: boundRoot.physicalRoot.standardizedFullPath
                )
            }
            return standardized
        }

        if let aliasTranslated = translateAliasPrefixedRelativePath(standardized) {
            return aliasTranslated
        }
        if isAliasPrefixedToUnboundLogicalRoot(standardized) {
            return rawPath
        }

        let boundRoots = Array(replacementsByLogicalRootPath.values)
        guard boundRoots.count == 1, let boundRoot = boundRoots.first else { return rawPath }
        return StandardizedPath.join(
            standardizedRoot: boundRoot.physicalRoot.standardizedFullPath,
            standardizedRelativePath: standardized
        )
    }

    func translateInputPaths(_ paths: [String]) -> [String] {
        paths.map { translateInputPath($0) }
    }

    func translateSliceInputs(_ slices: [WorkspaceSelectionSliceInput]) -> [WorkspaceSelectionSliceInput] {
        slices.map { input in
            WorkspaceSelectionSliceInput(
                path: translateInputPath(input.path),
                ranges: input.ranges
            )
        }
    }

    func projectedLogicalRootMetadata(forPhysicalPath rawPath: String) -> (rootPath: String, pathWithinRoot: String)? {
        let standardized = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let boundRoot = boundRoot(containingPhysicalAbsolutePath: standardized) else {
            return nil
        }
        let relative = String(standardized.dropFirst(boundRoot.physicalRoot.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (boundRoot.logicalRoot.standardizedFullPath, StandardizedPath.relative(relative))
    }

    func projectedLogicalPathComponents(forPhysicalPath rawPath: String) -> (root: WorkspaceRootRef, relativePath: String)? {
        let standardized = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let boundRoot = boundRoot(containingPhysicalAbsolutePath: standardized) else {
            return nil
        }
        let relative = String(standardized.dropFirst(boundRoot.physicalRoot.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (boundRoot.logicalRoot, StandardizedPath.relative(relative))
    }

    func projectedLogicalDisplayPath(forPhysicalPath rawPath: String, display: FilePathDisplay = .relative) -> String? {
        let standardized = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let boundRoot = boundRoot(containingPhysicalAbsolutePath: standardized) else {
            return nil
        }
        let logicalAbsolute = replacePrefix(
            in: standardized,
            from: boundRoot.physicalRoot.standardizedFullPath,
            to: boundRoot.logicalRoot.standardizedFullPath
        )
        if display == .full {
            return logicalAbsolute
        }
        let relative = String(logicalAbsolute.dropFirst(boundRoot.logicalRoot.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ClientPathFormatter.displayPath(
            root: boundRoot.logicalRoot,
            relativePath: relative,
            visibleRoots: visibleLogicalRootRefs
        )
    }

    func logicalDisplayPath(forPhysicalPath rawPath: String, display: FilePathDisplay = .relative) -> String {
        projectedLogicalDisplayPath(forPhysicalPath: rawPath, display: display)
            ?? StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
    }

    func logicalizeFileTreeSnapshot(_ snapshot: FileTreeSelectionSnapshot) -> FileTreeSelectionSnapshot {
        FileTreeSelectionSnapshot(
            roots: snapshot.roots.map { logicalizeFolderSnapshot($0) },
            selectedFileIDs: snapshot.selectedFileIDs,
            mode: snapshot.mode,
            showFullPaths: snapshot.showFullPaths,
            onlyIncludeRootsWithSelectedFiles: snapshot.onlyIncludeRootsWithSelectedFiles,
            includeLegend: snapshot.includeLegend,
            showCodeMapMarkers: snapshot.showCodeMapMarkers,
            maxDepth: snapshot.maxDepth
        )
    }

    private func logicalizeFolderSnapshot(_ folder: FileTreeFolderSnapshot) -> FileTreeFolderSnapshot {
        let logicalFullPath = projectedLogicalDisplayPath(forPhysicalPath: folder.fullPath, display: .full)
        let logicalStandardizedFullPath = projectedLogicalDisplayPath(forPhysicalPath: folder.standardizedFullPath, display: .full)
        let logicalStandardizedRootPath = projectedLogicalDisplayPath(forPhysicalPath: folder.standardizedRootPath, display: .full)
        let name: String = if let logicalStandardizedRootPath,
                              logicalStandardizedFullPath == logicalStandardizedRootPath,
                              let boundRoot = replacementsByLogicalRootPath[logicalStandardizedRootPath]
        {
            boundRoot.logicalRoot.name
        } else {
            folder.name
        }
        return FileTreeFolderSnapshot(
            id: folder.id,
            name: name,
            fullPath: logicalFullPath ?? folder.fullPath,
            standardizedFullPath: logicalStandardizedFullPath ?? folder.standardizedFullPath,
            standardizedRootPath: logicalStandardizedRootPath ?? folder.standardizedRootPath,
            children: folder.children.map { child in
                switch child {
                case let .folder(childFolder):
                    .folder(logicalizeFolderSnapshot(childFolder))
                case let .file(file):
                    .file(file)
                }
            }
        )
    }

    func logicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        var slices: [String: [LineRange]] = [:]
        for (path, ranges) in selection.slices {
            let logicalPath = logicalDisplayPath(forPhysicalPath: path, display: .full)
            slices[logicalPath] = SliceRangeMath.normalize((slices[logicalPath] ?? []) + ranges)
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.map { logicalDisplayPath(forPhysicalPath: $0, display: .full) },
            manualCodemapPaths: selection.manualCodemapPaths.map {
                logicalDisplayPath(forPhysicalPath: $0, display: .full)
            },
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    func physicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        var slices: [String: [LineRange]] = [:]
        for (path, ranges) in selection.slices {
            let physicalPath = translateInputPath(path)
            slices[physicalPath] = SliceRangeMath.normalize((slices[physicalPath] ?? []) + ranges)
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.map { translateInputPath($0) },
            manualCodemapPaths: selection.manualCodemapPaths.map { translateInputPath($0) },
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private func translateAliasPrefixedRelativePath(_ standardizedRelativePath: String) -> String? {
        switch WorkspaceAliasResolver.resolve(
            userPath: standardizedRelativePath,
            roots: visibleLogicalRootRefs,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .bareRoot(root, _):
            guard let boundRoot = replacementsByLogicalRootPath[root.standardizedFullPath] else { return nil }
            return boundRoot.physicalRoot.standardizedFullPath
        case let .prefixed(root, _, remainder):
            guard let boundRoot = replacementsByLogicalRootPath[root.standardizedFullPath] else { return nil }
            return StandardizedPath.join(
                standardizedRoot: boundRoot.physicalRoot.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
        case .ambiguous, .notAliasPrefixed:
            return nil
        }
    }

    private func isAliasPrefixedToUnboundLogicalRoot(_ standardizedRelativePath: String) -> Bool {
        switch WorkspaceAliasResolver.resolve(
            userPath: standardizedRelativePath,
            roots: visibleLogicalRootRefs,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .bareRoot(root, _), let .prefixed(root, _, _):
            replacementsByLogicalRootPath[root.standardizedFullPath] == nil
        case .ambiguous, .notAliasPrefixed:
            false
        }
    }

    private func boundRoot(containingLogicalAbsolutePath path: String) -> BoundRoot? {
        replacementsByLogicalRootPath.values
            .filter { path == $0.logicalRoot.standardizedFullPath || path.hasPrefix($0.logicalRoot.standardizedFullPath + "/") }
            .max { $0.logicalRoot.standardizedFullPath.count < $1.logicalRoot.standardizedFullPath.count }
    }

    func boundRoot(containingPhysicalAbsolutePath path: String) -> BoundRoot? {
        replacementsByLogicalRootPath.values
            .filter { path == $0.physicalRoot.standardizedFullPath || path.hasPrefix($0.physicalRoot.standardizedFullPath + "/") }
            .max { $0.physicalRoot.standardizedFullPath.count < $1.physicalRoot.standardizedFullPath.count }
    }

    private func pathIsUnderAnyPhysicalRoot(_ path: String) -> Bool {
        boundRoot(containingPhysicalAbsolutePath: path) != nil
    }

    private func replacePrefix(in path: String, from oldRoot: String, to newRoot: String) -> String {
        guard path != oldRoot else { return newRoot }
        let suffix = String(path.dropFirst(oldRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return StandardizedPath.join(standardizedRoot: newRoot, standardizedRelativePath: suffix)
    }
}

struct WorkspaceRootBindingProjectionPreparation {
    let sessionID: UUID
    let bindings: [AgentSessionWorktreeBinding]
    let visibleRoots: [WorkspaceRootRef]
    let ownership: WorkspaceSessionWorktreeOwnershipPreparation
    let startupContext: WorktreeStartupContext?
}

struct WorkspaceRootBindingProjectionMaterializer {
    let store: WorkspaceFileContextStore

    func prepare(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding],
        startupContext: WorktreeStartupContext? = nil,
        initializationHintsByBindingID: [String: WorkspaceRootMaterializationHint] = [:]
    ) async throws -> WorkspaceRootBindingProjectionPreparation {
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        return try await prepare(
            sessionID: sessionID,
            bindings: bindings,
            visibleRoots: visibleRoots,
            startupContext: startupContext,
            initializationHintsByBindingID: initializationHintsByBindingID
        )
    }

    private func prepare(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding],
        visibleRoots: [WorkspaceRootRef],
        startupContext: WorktreeStartupContext?,
        initializationHintsByBindingID: [String: WorkspaceRootMaterializationHint]
    ) async throws -> WorkspaceRootBindingProjectionPreparation {
        var initializationHintsByPhysicalRootPath: [String: WorkspaceRootMaterializationHint] = [:]
        #if DEBUG
            var receiptProjectionDecision = WorktreeStartupInstrumentation.ReceiptProjectionDecision()
            receiptProjectionDecision.suppliedHintCount = initializationHintsByBindingID.count
            receiptProjectionDecision.allHintKeysMatchedBindings = Set(initializationHintsByBindingID.keys)
                .isSubset(of: Set(bindings.map(\.id)))
        #endif
        for binding in bindings {
            guard let hint = initializationHintsByBindingID[binding.id] else { continue }
            let physicalPath = StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath)
            let validatedHint = hint.validated(
                matching: binding,
                sessionID: sessionID,
                startupContext: startupContext
            )
            initializationHintsByPhysicalRootPath[physicalPath] = validatedHint
            #if DEBUG
                receiptProjectionDecision.matchedHintCount += 1
                receiptProjectionDecision.validationFallback = receiptProjectionDecision.validationFallback
                    ?? validatedHint.validationFallbackReason
            #endif
        }
        #if DEBUG
            if let startupContext {
                WorktreeStartupInstrumentation.recordReceiptProjectionDecision(
                    correlationID: startupContext.correlationID,
                    decision: receiptProjectionDecision
                )
            }
        #endif
        let ownership = try await store.prepareSessionWorktreeOwnership(
            ownerID: sessionID,
            bindingFingerprint: AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(bindings),
            physicalRootPaths: bindings.map(\.worktreeRootPath),
            startupContext: startupContext,
            initializationHintsByPhysicalRootPath: initializationHintsByPhysicalRootPath
        )
        return WorkspaceRootBindingProjectionPreparation(
            sessionID: sessionID,
            bindings: bindings,
            visibleRoots: visibleRoots,
            ownership: ownership,
            startupContext: startupContext
        )
    }

    func commit(
        _ preparation: WorkspaceRootBindingProjectionPreparation
    ) async throws -> WorkspaceRootBindingProjection? {
        let records: [WorkspaceSessionWorktreeOwnedRoot]
        do {
            records = try await store.commitSessionWorktreeOwnership(preparation.ownership)
        } catch {
            #if DEBUG
                await store.terminalizeReceiptConsumptionDecision(preparation.ownership)
            #endif
            throw error
        }
        if let startupContext = preparation.startupContext {
            WorktreeStartupInstrumentation.record(.rootReady, context: startupContext)
        }
        guard !preparation.bindings.isEmpty else { return nil }

        let recordsByPath = Dictionary(uniqueKeysWithValues: records.map {
            ($0.standardizedPhysicalPath, $0)
        })
        var boundRoots: [WorkspaceRootBindingProjection.BoundRoot] = []
        for binding in preparation.bindings {
            let logicalRoot = logicalRoot(for: binding, visibleRoots: preparation.visibleRoots)
            let physicalPath = StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath)
            guard let physicalRecord = recordsByPath[physicalPath] else {
                await store.releaseSessionWorktreeOwnership(ownerID: preparation.sessionID)
                throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(physicalPath)
            }
            let physicalRoot = WorkspaceRootRef(
                id: physicalRecord.rootID,
                name: logicalRoot.name,
                fullPath: physicalRecord.standardizedPhysicalPath
            )
            boundRoots.append(.init(
                logicalRoot: logicalRoot,
                physicalRoot: physicalRoot,
                binding: binding,
                sessionRootAuthorization: WorkspaceSessionRootAuthorization(
                    sessionID: preparation.sessionID,
                    ownershipGeneration: preparation.ownership.token.generation,
                    root: physicalRoot,
                    lifetimeID: physicalRecord.lifetimeID
                )
            ))
        }
        return WorkspaceRootBindingProjection(
            sessionID: preparation.sessionID,
            boundRoots: boundRoots,
            visibleLogicalRoots: preparation.visibleRoots
        )
    }

    func abort(_ preparation: WorkspaceRootBindingProjectionPreparation) async {
        await store.abortSessionWorktreeOwnership(preparation.ownership)
    }

    func release(sessionID: UUID) async {
        await store.releaseSessionWorktreeOwnership(ownerID: sessionID)
    }

    func materialize(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding]
    ) async -> WorkspaceRootBindingProjection? {
        await FileSystemService.withContentReadForegroundActivity(kind: .materialization) {
            await materializeWithinForegroundActivity(
                sessionID: sessionID,
                bindings: bindings
            )
        }
    }

    private func materializeWithinForegroundActivity(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding]
    ) async -> WorkspaceRootBindingProjection? {
        #if DEBUG
            let coldStartCollector = WorkspaceFileSearchDebugContext.coldStartCollector
            let materializationStart = WorkspaceFileSearchDebugTiming.now()
            var prepareNanoseconds: UInt64 = 0
            var commitNanoseconds: UInt64 = 0
        #endif
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        do {
            #if DEBUG
                let prepareStart = WorkspaceFileSearchDebugTiming.now()
            #endif
            let preparation = try await prepare(
                sessionID: sessionID,
                bindings: bindings,
                visibleRoots: visibleRoots,
                startupContext: nil,
                initializationHintsByBindingID: [:]
            )
            #if DEBUG
                prepareNanoseconds = WorkspaceFileSearchDebugTiming.elapsed(
                    since: prepareStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
            #endif
            do {
                #if DEBUG
                    let commitStart = WorkspaceFileSearchDebugTiming.now()
                #endif
                let projection = try await commit(preparation)
                #if DEBUG
                    commitNanoseconds = WorkspaceFileSearchDebugTiming.elapsed(
                        since: commitStart,
                        through: WorkspaceFileSearchDebugTiming.now()
                    )
                    coldStartCollector?.recordMaterialization(
                        totalNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                            since: materializationStart,
                            through: WorkspaceFileSearchDebugTiming.now()
                        ),
                        prepareNanoseconds: prepareNanoseconds,
                        commitNanoseconds: commitNanoseconds
                    )
                #endif
                return projection
            } catch {
                await abort(preparation)
                #if DEBUG
                    coldStartCollector?.recordMaterialization(
                        totalNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                            since: materializationStart,
                            through: WorkspaceFileSearchDebugTiming.now()
                        ),
                        prepareNanoseconds: prepareNanoseconds,
                        commitNanoseconds: commitNanoseconds
                    )
                #endif
                return failClosedProjection(
                    sessionID: sessionID,
                    bindings: bindings,
                    visibleRoots: visibleRoots
                )
            }
        } catch {
            #if DEBUG
                coldStartCollector?.recordMaterialization(
                    totalNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: materializationStart,
                        through: WorkspaceFileSearchDebugTiming.now()
                    ),
                    prepareNanoseconds: prepareNanoseconds,
                    commitNanoseconds: commitNanoseconds
                )
            #endif
            return failClosedProjection(
                sessionID: sessionID,
                bindings: bindings,
                visibleRoots: visibleRoots
            )
        }
    }

    private func failClosedProjection(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding],
        visibleRoots: [WorkspaceRootRef]
    ) -> WorkspaceRootBindingProjection? {
        guard !bindings.isEmpty else { return nil }
        let boundRoots = bindings.map { binding in
            let logicalRoot = logicalRoot(for: binding, visibleRoots: visibleRoots)
            let physicalPath = StandardizedPath.absolute(
                (binding.worktreeRootPath as NSString).expandingTildeInPath
            )
            return WorkspaceRootBindingProjection.BoundRoot(
                logicalRoot: logicalRoot,
                physicalRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: logicalRoot.name,
                    fullPath: physicalPath
                ),
                binding: binding,
                sessionRootAuthorization: nil
            )
        }
        return WorkspaceRootBindingProjection(
            sessionID: sessionID,
            boundRoots: boundRoots,
            visibleLogicalRoots: visibleRoots,
            lookupPhysicalRootPaths: []
        )
    }

    private func logicalRoot(
        for binding: AgentSessionWorktreeBinding,
        visibleRoots: [WorkspaceRootRef]
    ) -> WorkspaceRootRef {
        let logicalPath = StandardizedPath.absolute(
            (binding.logicalRootPath as NSString).expandingTildeInPath
        )
        return visibleRoots.first { $0.standardizedFullPath == logicalPath }
            ?? WorkspaceRootRef(
                id: UUID(),
                name: binding.logicalRootName ?? URL(fileURLWithPath: logicalPath).lastPathComponent,
                fullPath: logicalPath
            )
    }
}

struct WorkspaceLookupContext: Equatable {
    let rootScope: WorkspaceLookupRootScope
    let bindingProjection: WorkspaceRootBindingProjection?

    static let visibleWorkspace = WorkspaceLookupContext(rootScope: .visibleWorkspace, bindingProjection: nil)

    func translateInputPath(_ path: String) -> String {
        bindingProjection?.translateInputPath(path) ?? path
    }

    func translateInputPaths(_ paths: [String]) -> [String] {
        bindingProjection?.translateInputPaths(paths) ?? paths
    }

    func translateSliceInputs(_ slices: [WorkspaceSelectionSliceInput]) -> [WorkspaceSelectionSliceInput] {
        bindingProjection?.translateSliceInputs(slices) ?? slices
    }

    func displayPath(forPhysicalPath path: String, display: FilePathDisplay = .relative) -> String {
        bindingProjection?.logicalDisplayPath(forPhysicalPath: path, display: display) ?? path
    }

    func logicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        bindingProjection?.logicalizeSelection(selection) ?? selection
    }

    func physicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        bindingProjection?.physicalizeSelection(selection) ?? selection
    }
}
