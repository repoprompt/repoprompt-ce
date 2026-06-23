import Foundation
import RepoPromptCore

extension MCPRuntimeRoutingTableSnapshot {
    func bindingMatches(contextID: UUID) -> [MCPContextBindingMatch] {
        mappings.compactMap { mapping in
            for workspace in mapping.workspaces {
                guard workspace.composeTabs.contains(where: { $0.id == contextID }) else { continue }
                return MCPContextBindingMatch(
                    windowID: mapping.windowID,
                    runtimeID: mapping.runtimeID,
                    mappingGeneration: mapping.mappingGeneration,
                    tabID: contextID,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    repoPaths: workspace.orderedRootPaths,
                    sessionID: mapping.sessionID,
                    sessionAvailability: mapping.workspaceSessionAvailability
                )
            }
            return nil
        }
    }

    func bindingMatches(workingDirs: [String]) -> [MCPContextBindingMatch] {
        let normalizedDirs = workingDirs.map(Self.normalizeBindingPath).filter { !$0.isEmpty }
        guard !normalizedDirs.isEmpty else { return [] }
        return mappings.compactMap { mapping in
            guard let activeWorkspaceID = mapping.activeWorkspaceID,
                  let workspace = mapping.workspaces.first(where: {
                      $0.id == activeWorkspaceID && !$0.isHiddenInMenus
                  }),
                  Self.workspaceRoots(workspace.orderedRootPaths, contain: normalizedDirs),
                  let tab = workspace.composeTabs.first(where: { $0.id == workspace.activeComposeTabID })
                  ?? workspace.composeTabs.first
            else { return nil }
            return MCPContextBindingMatch(
                windowID: mapping.windowID,
                runtimeID: mapping.runtimeID,
                mappingGeneration: mapping.mappingGeneration,
                tabID: tab.id,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                repoPaths: workspace.orderedRootPaths,
                sessionID: mapping.sessionID,
                sessionAvailability: mapping.workspaceSessionAvailability
            )
        }
    }

    private static func workspaceRoots(_ rootPaths: [String], contain dirs: [String]) -> Bool {
        let roots = rootPaths.map(normalizeBindingPath).filter { !$0.isEmpty }
        guard !roots.isEmpty else { return false }
        return dirs.allSatisfy { dir in
            roots.contains { root in
                dir == root || dir.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
    }

    private static func normalizeBindingPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(
            fileURLWithPath: (trimmed as NSString).expandingTildeInPath
        ).standardizedFileURL.path
    }
}

private extension MCPRuntimeRoutingSnapshot {
    var workspaceSessionAvailability: WorkspaceSessionAvailability {
        switch availability {
        case .created: .created
        case .hydrating: .hydrating
        case .awaitingActivation: .awaitingActivation
        case .active: .active
        case .switching: .switching
        case let .failed(message): .failed(message)
        case .closing: .closing
        case .closed: .closed
        }
    }
}
