import Foundation

enum MCPManageSelectionArtifactUse: Equatable {
    case remove
    case insert
}

enum MCPManageSelectionArtifactSource: Equatable {
    case currentSelection
    case advertisedGrant(generation: UInt64)
}

struct MCPManageSelectionResolvedArtifact: Equatable {
    let alias: String
    let absolutePath: String
    let source: MCPManageSelectionArtifactSource
}

struct MCPManageSelectionArtifactAuthorizationFence: Equatable {
    let identity: WorkspaceSelectionIdentity
    let capability: SelectedGitArtifactCapability
    let grantSnapshot: MCPGitArtifactAdvertisementSnapshot?
}

struct MCPManageSelectionArtifactResolutionRequest {
    let paths: [String]
    let sliceInputs: [WorkspaceSelectionSliceInput]
    let use: MCPManageSelectionArtifactUse
    let mode: String
    let physicalSelection: StoredSelection
    let identity: WorkspaceSelectionIdentity?
    let capability: SelectedGitArtifactCapability?
}

struct MCPManageSelectionArtifactResolution: Equatable {
    let ordinaryPaths: [String]
    let ordinarySliceInputs: [WorkspaceSelectionSliceInput]
    let artifacts: [MCPManageSelectionResolvedArtifact]
    let invalidDiagnostics: [String]
    let fence: MCPManageSelectionArtifactAuthorizationFence?

    var absolutePaths: [String] {
        artifacts.map(\.absolutePath)
    }

    var resolvedCount: Int {
        artifacts.count
    }

    var hasArtifactInputs: Bool {
        !artifacts.isEmpty || !invalidDiagnostics.isEmpty
    }
}

/// Resolves only exact "_git_data/..." aliases. It never constructs an insertion path from input,
/// enumerates a Git-data root, expands folders, performs fuzzy lookup, or reads outside the catalog.
@MainActor
struct MCPManageSelectionArtifactResolver {
    let store: WorkspaceFileContextStore
    let registry: MCPGitArtifactAdvertisementRegistry
    let authorizationService: SelectedGitDiffArtifactAuthorizationService

    init(
        store: WorkspaceFileContextStore,
        registry: MCPGitArtifactAdvertisementRegistry,
        authorizationService: SelectedGitDiffArtifactAuthorizationService = .init()
    ) {
        self.store = store
        self.registry = registry
        self.authorizationService = authorizationService
    }

    func resolve(
        _ request: MCPManageSelectionArtifactResolutionRequest
    ) async -> MCPManageSelectionArtifactResolution {
        let artifactSliceAliases = Set(request.sliceInputs.compactMap { input -> String? in
            let trimmed = input.path.trimmingCharacters(in: .whitespacesAndNewlines)
            return isArtifactShaped(trimmed) ? trimmed : nil
        })
        let ordinarySlices = request.sliceInputs.filter {
            !isArtifactShaped($0.path.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var ordinaryPaths: [String] = []
        var candidateTuples: [(alias: String, path: String, source: MCPManageSelectionArtifactSource)] = []
        var invalid: [String] = []
        var insertionSnapshot: MCPGitArtifactAdvertisementSnapshot?

        let selectedAliases: [String: String] = if let capability = request.capability {
            aliasesForCurrentSelection(
                request.physicalSelection,
                capability: capability
            )
        } else {
            [:]
        }

        for rawPath in request.paths {
            let alias = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isArtifactShaped(alias) else {
                ordinaryPaths.append(rawPath)
                continue
            }
            guard isValidAlias(alias) else {
                appendUnique("\(alias): malformed Git artifact alias", to: &invalid)
                continue
            }
            guard request.mode == "full" else {
                appendUnique("\(alias): Git artifacts support mode 'full' only", to: &invalid)
                continue
            }
            guard !artifactSliceAliases.contains(alias) else {
                appendUnique("\(alias): Git artifacts do not support slices", to: &invalid)
                continue
            }
            guard let identity = request.identity,
                  let capability = request.capability
            else {
                appendUnique("\(alias): Git artifact capability is unavailable", to: &invalid)
                continue
            }
            guard await currentRootMatches(capability) else {
                appendUnique("\(alias): frozen Git-data root was unloaded or reloaded", to: &invalid)
                continue
            }

            switch request.use {
            case .remove:
                guard let path = selectedAliases[alias] else {
                    appendUnique("\(alias): alias is not selected", to: &invalid)
                    continue
                }
                candidateTuples.append((alias, path, .currentSelection))
            case .insert:
                switch registry.lookup(
                    exactAlias: alias,
                    identity: identity,
                    capability: capability
                ) {
                case let .granted(artifact, snapshot):
                    if let insertionSnapshot, insertionSnapshot != snapshot {
                        appendUnique("\(alias): artifact advertisement was replaced", to: &invalid)
                    } else {
                        insertionSnapshot = snapshot
                        candidateTuples.append((
                            alias,
                            artifact.absolutePath,
                            .advertisedGrant(generation: snapshot.generation)
                        ))
                    }
                case let .rejected(reason):
                    appendUnique("\(alias): \(reason.diagnosticLabel)", to: &invalid)
                }
            }
        }

        for alias in artifactSliceAliases where !request.paths.contains(alias) {
            appendUnique("\(alias): Git artifacts do not support slices", to: &invalid)
        }

        guard let identity = request.identity,
              let capability = request.capability,
              !candidateTuples.isEmpty
        else {
            return MCPManageSelectionArtifactResolution(
                ordinaryPaths: ordinaryPaths,
                ordinarySliceInputs: ordinarySlices,
                artifacts: [],
                invalidDiagnostics: invalid,
                fence: nil
            )
        }

        let authorization = await authorizationService.authorizeExactPaths(
            ExactSelectedGitArtifactAuthorizationRequest(
                exactAbsolutePaths: candidateTuples.map(\.path),
                capability: capability,
                store: store
            )
        )
        let dispositionByPath = authorization.dispositionsByAbsolutePath
        var artifacts: [MCPManageSelectionResolvedArtifact] = []
        var seen = Set<String>()
        for candidate in candidateTuples {
            guard seen.insert(candidate.alias).inserted else { continue }
            switch dispositionByPath[candidate.path] {
            case .authorized:
                artifacts.append(
                    MCPManageSelectionResolvedArtifact(
                        alias: candidate.alias,
                        absolutePath: candidate.path,
                        source: candidate.source
                    )
                )
            case let .rejected(_, reason):
                appendUnique("\(candidate.alias): \(reason.diagnosticLabel)", to: &invalid)
            case nil:
                appendUnique("\(candidate.alias): exact artifact authorization failed", to: &invalid)
            }
        }

        let fence = artifacts.isEmpty ? nil : MCPManageSelectionArtifactAuthorizationFence(
            identity: identity,
            capability: capability,
            grantSnapshot: request.use == .insert ? insertionSnapshot : nil
        )
        return MCPManageSelectionArtifactResolution(
            ordinaryPaths: ordinaryPaths,
            ordinarySliceInputs: ordinarySlices,
            artifacts: artifacts,
            invalidDiagnostics: invalid,
            fence: fence
        )
    }

    private func aliasesForCurrentSelection(
        _ selection: StoredSelection,
        capability: SelectedGitArtifactCapability
    ) -> [String: String] {
        var paths: [String] = []
        var seen = Set<String>()
        func append(_ rawPath: String) {
            guard let path = StoredSelectionPathNormalization.standardizedPath(rawPath),
                  seen.insert(path).inserted
            else { return }
            paths.append(path)
        }

        selection.selectedPaths.forEach(append)
        selection.slices
            .filter { !$0.value.isEmpty }
            .keys
            .forEach(append)

        var aliases: [String: String] = [:]
        let root = capability.gitDataRoot.standardizedFullPath
        for path in paths where StandardizedPath.isDescendant(path, of: root) {
            let relative = String(path.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(relative) else { continue }
            aliases["_git_data/\(relative)"] = path
        }
        return aliases
    }

    private func currentRootMatches(_ capability: SelectedGitArtifactCapability) async -> Bool {
        let expectedPath = StandardizedPath.join(
            standardizedRoot: capability.workspaceDirectoryPath,
            standardizedRelativePath: "_git_data"
        )
        guard expectedPath == capability.gitDataRoot.standardizedFullPath else { return false }
        return await store.exactRootRef(
            path: expectedPath,
            kind: .workspaceGitData
        ) == capability.gitDataRoot
    }

    private func isArtifactShaped(_ path: String) -> Bool {
        path == "_git_data" || path.hasPrefix("_git_data/")
    }

    private func isValidAlias(_ alias: String) -> Bool {
        guard alias.hasPrefix("_git_data/") else { return false }
        let relative = String(alias.dropFirst("_git_data/".count))
        return GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(relative)
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }
}
