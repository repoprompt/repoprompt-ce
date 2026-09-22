import CryptoKit
import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime

struct DirectHeadlessRootMapping: Equatable {
    let canonicalRoot: URL
    let physicalRoot: URL
    let worktree: DirectHeadlessGitWorktree?
    let visualLabel: String?
    let visualColorHex: String?
}

struct DirectHeadlessRootOverlay: Equatable {
    let mappings: [DirectHeadlessRootMapping]
    let activeRoot: URL?
}

struct DirectHeadlessInitialRoute: Equatable {
    let bindingWorkingDirectories: [URL]
    let rootOverlay: DirectHeadlessRootOverlay
}

struct DirectHeadlessGitWorktree: Equatable {
    let repositoryID: String
    let repoKey: String
    let worktreeID: String
    let path: URL
    let gitDirectory: URL
    let branch: String?
    let head: String?
    let isMain: Bool
}

struct DirectHeadlessSessionSelector {
    let selector: String?
    let worktreeID: String?
    let create: Bool
}

enum DirectHeadlessWorktreeRouting {
    static func resolveInitialRoute(
        workingDirectories: [URL],
        catalog: DomainWorkspaceCatalogSnapshot
    ) async throws -> DirectHeadlessInitialRoute {
        guard !workingDirectories.isEmpty else {
            return DirectHeadlessInitialRoute(
                bindingWorkingDirectories: [],
                rootOverlay: DirectHeadlessRootOverlay(mappings: [], activeRoot: nil)
            )
        }

        let physicalRoots = workingDirectories.map(canonicalPath)
        var physicalWorktreeInventories: [[DirectHeadlessGitWorktree]?] = []
        for physicalRoot in physicalRoots {
            guard let inventory = try? await listWorktrees(repositoryRoot: physicalRoot),
                  let physicalWorktree = containingWorktree(for: physicalRoot, in: inventory),
                  await (try? verifyWorktree(physicalWorktree)) != nil
            else {
                physicalWorktreeInventories.append(nil)
                continue
            }
            physicalWorktreeInventories.append(inventory)
        }
        var candidates: [DirectHeadlessInitialRoute] = []
        for workspace in catalog.workspaces {
            let canonicalRoots = workspace.document.metadata.repoPaths.map {
                canonicalPath(URL(fileURLWithPath: $0, isDirectory: true))
            }
            guard canonicalRoots.count == physicalRoots.count,
                  let mappings = exactMappings(
                      canonicalRoots: canonicalRoots,
                      physicalRoots: physicalRoots,
                      physicalWorktreeInventories: physicalWorktreeInventories
                  )
            else { continue }
            let needsOverlay = mappings.contains {
                canonicalPath($0.canonicalRoot).path != canonicalPath($0.physicalRoot).path
                    || $0.worktree != nil
            }
            candidates.append(DirectHeadlessInitialRoute(
                bindingWorkingDirectories: canonicalRoots,
                rootOverlay: needsOverlay
                    ? DirectHeadlessRootOverlay(mappings: mappings, activeRoot: physicalRoots.first)
                    : DirectHeadlessRootOverlay(mappings: [], activeRoot: nil)
            ))
        }
        if candidates.count > 1, !candidates.dropFirst().allSatisfy({ routesAreEquivalent($0, candidates[0]) }) {
            throw MCPError.invalidRequest(
                "working directories match multiple saved workspaces after existing-worktree resolution"
            )
        }
        guard let route = candidates.first else {
            return DirectHeadlessInitialRoute(
                bindingWorkingDirectories: physicalRoots,
                rootOverlay: DirectHeadlessRootOverlay(mappings: [], activeRoot: nil)
            )
        }
        return route
    }

    static func resolveSessionOverlay(
        arguments: [String: Value],
        selectorIntent: DirectHeadlessSessionSelector,
        canonicalRoots: [URL],
        baseOverlay: DirectHeadlessRootOverlay
    ) async throws -> DirectHeadlessRootOverlay {
        let selector = selectorIntent.selector
        let worktreeID = selectorIntent.worktreeID
        let visualLabel = normalized(arguments["worktree_label"]?.stringValue)
        let visualColorHex = normalized(arguments["worktree_color"]?.stringValue)
        if selectorIntent.create {
            throw MCPError.invalidRequest("direct headless agent_run does not create worktrees; pass an exact existing worktree selector")
        }
        let creationOnlyKeys = [
            "worktree_branch",
            "worktree_base_ref",
            "worktree_path",
            "allow_external_worktree_path"
        ]
        if creationOnlyKeys.contains(where: { arguments[$0] != nil }) {
            throw MCPError.invalidParams("worktree creation arguments require worktree_create=true, which direct headless does not support")
        }
        let selectorOnlyKeys = ["worktree_repo_root", "worktree_label", "worktree_color"]
        if selector == nil, worktreeID == nil, selectorOnlyKeys.contains(where: { arguments[$0] != nil }) {
            throw MCPError.invalidParams("worktree_repo_root, worktree_label, and worktree_color require an existing worktree selector")
        }
        guard selector != nil || worktreeID != nil else { return baseOverlay }
        if let visualColorHex, !isHexColor(visualColorHex) {
            throw MCPError.invalidParams("worktree_color must be a valid #RRGGBB value")
        }

        let logicalRoot = try selectLogicalRoot(
            arguments["worktree_repo_root"]?.stringValue,
            canonicalRoots: canonicalRoots,
            mappings: baseOverlay.mappings
        )
        let currentPhysicalRoot = baseOverlay.mappings.first(where: {
            canonicalPath($0.canonicalRoot).path == canonicalPath(logicalRoot).path
        })?.physicalRoot ?? logicalRoot
        let worktrees = try await listWorktrees(repositoryRoot: logicalRoot)
        let selected = try selectWorktree(
            selector: selector,
            worktreeID: worktreeID,
            currentPhysicalRoot: currentPhysicalRoot,
            worktrees: worktrees
        )
        guard FileManager.default.fileExists(atPath: selected.path.path) else {
            throw MCPError.invalidRequest("selected worktree path is unavailable: \(selected.path.path)")
        }
        try await verifyWorktree(selected)
        guard let canonicalWorktree = containingWorktree(for: logicalRoot, in: worktrees),
              let suffix = relativeSuffix(of: logicalRoot, within: canonicalWorktree.path)
        else {
            throw MCPError.invalidRequest("workspace root is not contained by the selected Git repository")
        }
        let unresolvedSelectedRoot = suffix.isEmpty
            ? selected.path
            : selected.path.appendingPathComponent(suffix, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: unresolvedSelectedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let selectedSuffix = relativeSuffix(of: unresolvedSelectedRoot, within: selected.path),
              selectedSuffix == suffix
        else {
            throw MCPError.invalidRequest(
                "selected worktree workspace root does not preserve the logical root fence: \(unresolvedSelectedRoot.path)"
            )
        }
        let selectedPhysicalRoot = canonicalPath(unresolvedSelectedRoot)

        var result = baseOverlay.mappings.filter {
            canonicalPath($0.canonicalRoot).path != canonicalPath(logicalRoot).path
        }
        result.append(DirectHeadlessRootMapping(
            canonicalRoot: canonicalPath(logicalRoot),
            physicalRoot: canonicalPath(selectedPhysicalRoot),
            worktree: selected,
            visualLabel: visualLabel,
            visualColorHex: visualColorHex?.uppercased()
        ))
        let mappings = try canonicalRoots.map { canonical in
            let matches = result.filter {
                canonicalPath($0.canonicalRoot).path == canonicalPath(canonical).path
            }
            guard matches.count == 1, let match = matches.first else {
                throw MCPError.internalError("direct-headless worktree mapping became incomplete or ambiguous")
            }
            return match
        }
        return DirectHeadlessRootOverlay(
            mappings: mappings,
            activeRoot: canonicalPath(selectedPhysicalRoot)
        )
    }

    static func parseSessionSelector(arguments: [String: Value]) throws -> DirectHeadlessSessionSelector {
        let selector = normalized(arguments["worktree"]?.stringValue)
        let worktreeID = normalized(arguments["worktree_id"]?.stringValue)
        if arguments["worktree"] != nil, selector == nil {
            throw MCPError.invalidParams("worktree must be a non-empty string")
        }
        if arguments["worktree_id"] != nil, worktreeID == nil {
            throw MCPError.invalidParams("worktree_id must be a non-empty string")
        }
        let create = arguments["worktree_create"]?.boolValue == true
        let selectorCount = [selector != nil, worktreeID != nil, create].count(where: { $0 })
        guard selectorCount <= 1 else {
            throw MCPError.invalidParams("worktree, worktree_id, and worktree_create are mutually exclusive for agent_run start")
        }
        return DirectHeadlessSessionSelector(
            selector: selector,
            worktreeID: worktreeID,
            create: create
        )
    }

    static func listWorktrees(repositoryRoot: URL) async throws -> [DirectHeadlessGitWorktree] {
        let root = canonicalPath(repositoryRoot)
        let commonDirectory = try await gitURL(root: root, arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let repositoryID = "gitrepo_\(sha256(commonDirectory.path))"
        let output = try await DirectProcess.run(
            "/usr/bin/git",
            arguments: ["-C", root.path, "worktree", "list", "--porcelain"]
        )
        let records = porcelainRecords(output)
        struct ResolvedRecord {
            let record: PorcelainRecord
            let path: URL
            let gitDirectory: URL
            let isMain: Bool
        }
        var resolvedRecords: [ResolvedRecord] = []
        for record in records {
            let path = canonicalPath(URL(fileURLWithPath: record.path, isDirectory: true))
            guard let layout = gitLayout(worktreeRoot: path) else { continue }
            let gitDirectory = layout.gitDirectory
            let candidateCommon = layout.commonDirectory
            guard sameDirectoryIdentity(candidateCommon, commonDirectory) else {
                throw MCPError.invalidRequest("listed worktree repository identity changed: \(record.path)")
            }
            let isMain = sameDirectoryIdentity(gitDirectory, commonDirectory)
            resolvedRecords.append(ResolvedRecord(
                record: record,
                path: path,
                gitDirectory: gitDirectory,
                isMain: isMain
            ))
        }
        let repositoryName = resolvedRecords.first(where: \.isMain)?.path.lastPathComponent
            ?? commonDirectory.deletingLastPathComponent().lastPathComponent
        let repoKey = "\(slug(repositoryName))-\(sha256(commonDirectory.path).prefix(8))"
        return resolvedRecords.map { resolved in
            let record = resolved.record
            let path = resolved.path
            let gitDirectory = resolved.gitDirectory
            let isMain = resolved.isMain
            let stableComponent = isMain ? "main" : gitDirectory.path
            return DirectHeadlessGitWorktree(
                repositoryID: repositoryID,
                repoKey: repoKey,
                worktreeID: "wt_\(sha256("\(repositoryID)\u{0}\(stableComponent)"))",
                path: path,
                gitDirectory: gitDirectory,
                branch: record.branch,
                head: record.head,
                isMain: isMain
            )
        }
    }

    static func binding(
        mapping: DirectHeadlessRootMapping,
        source: String
    ) -> DomainAgentRunSnapshot.WorktreeBinding? {
        guard let worktree = mapping.worktree else { return nil }
        return DomainAgentRunSnapshot.WorktreeBinding(
            id: "\(worktree.repositoryID):\(worktree.worktreeID)",
            repositoryID: worktree.repositoryID,
            repoKey: worktree.repoKey,
            logicalRootPath: mapping.canonicalRoot.path,
            logicalRootName: mapping.canonicalRoot.lastPathComponent,
            worktreeID: worktree.worktreeID,
            worktreeRootPath: worktree.path.path,
            worktreeName: worktree.path.lastPathComponent,
            branch: worktree.branch,
            head: worktree.head,
            visualLabel: mapping.visualLabel,
            visualColorHex: mapping.visualColorHex,
            boundAt: Date(),
            source: source,
            unavailable: false
        )
    }

    static func verifyMappingsAtUse(_ mappings: [DirectHeadlessRootMapping]) async throws {
        for mapping in mappings {
            guard let worktree = mapping.worktree else { continue }
            guard canonicalPath(mapping.physicalRoot).path == mapping.physicalRoot.path,
                  relativeSuffix(of: mapping.physicalRoot, within: worktree.path) != nil
            else {
                throw MCPError.invalidRequest(
                    "selected worktree path identity changed: \(mapping.physicalRoot.path)"
                )
            }
            try await verifyWorktree(worktree)
        }
    }

    private static func exactMappings(
        canonicalRoots: [URL],
        physicalRoots: [URL],
        physicalWorktreeInventories: [[DirectHeadlessGitWorktree]?]
    ) -> [DirectHeadlessRootMapping]? {
        var remaining = Array(physicalRoots.indices)
        var result: [DirectHeadlessRootMapping] = []
        for canonicalRoot in canonicalRoots {
            if let remainingIndex = remaining.firstIndex(where: {
                canonicalPath(physicalRoots[$0]).path == canonicalPath(canonicalRoot).path
            }) {
                let physicalIndex = remaining.remove(at: remainingIndex)
                result.append(DirectHeadlessRootMapping(
                    canonicalRoot: canonicalPath(canonicalRoot),
                    physicalRoot: canonicalPath(physicalRoots[physicalIndex]),
                    worktree: nil,
                    visualLabel: nil,
                    visualColorHex: nil
                ))
                continue
            }
            let matches = remaining.enumerated().compactMap {
                remainingIndex, physicalIndex -> (remainingIndex: Int, physicalIndex: Int, worktree: DirectHeadlessGitWorktree)? in
                guard let inventory = physicalWorktreeInventories[physicalIndex],
                      let canonicalWorktree = containingWorktree(for: canonicalRoot, in: inventory),
                      let physicalWorktree = containingWorktree(for: physicalRoots[physicalIndex], in: inventory),
                      relativeSuffix(of: canonicalRoot, within: canonicalWorktree.path)
                      == relativeSuffix(of: physicalRoots[physicalIndex], within: physicalWorktree.path)
                else { return nil }
                return (remainingIndex, physicalIndex, physicalWorktree)
            }
            guard matches.count == 1, let match = matches.first else { return nil }
            remaining.remove(at: match.remainingIndex)
            result.append(DirectHeadlessRootMapping(
                canonicalRoot: canonicalPath(canonicalRoot),
                physicalRoot: canonicalPath(physicalRoots[match.physicalIndex]),
                worktree: match.worktree,
                visualLabel: nil,
                visualColorHex: nil
            ))
        }
        return remaining.isEmpty ? result : nil
    }

    private static func selectLogicalRoot(
        _ selector: String?,
        canonicalRoots: [URL],
        mappings: [DirectHeadlessRootMapping]
    ) throws -> URL {
        guard let selector = normalized(selector) else {
            guard let root = canonicalRoots.first else {
                throw MCPError.invalidParams("workspace has no declared root")
            }
            return root
        }
        let matches = canonicalRoots.filter { canonical in
            let mapping = mappings.first { canonicalPath($0.canonicalRoot).path == canonicalPath(canonical).path }
            return selector == canonical.path
                || selector == canonical.lastPathComponent
                || mapping.map { selector == $0.physicalRoot.path } == true
        }
        guard matches.count == 1, let root = matches.first else {
            throw MCPError.invalidParams("worktree_repo_root is unknown or ambiguous")
        }
        return root
    }

    private static func selectWorktree(
        selector: String?,
        worktreeID: String?,
        currentPhysicalRoot: URL,
        worktrees: [DirectHeadlessGitWorktree]
    ) throws -> DirectHeadlessGitWorktree {
        let matches: [DirectHeadlessGitWorktree]
        if let worktreeID {
            matches = worktrees.filter { $0.worktreeID == worktreeID }
        } else if let selector {
            if selector == "@current" {
                matches = worktrees.filter { relativeSuffix(of: currentPhysicalRoot, within: $0.path) != nil }
            } else if selector == "@main" {
                matches = worktrees.filter(\.isMain)
            } else if selector.hasPrefix("@id:") {
                matches = worktrees.filter { $0.worktreeID == String(selector.dropFirst(4)) }
            } else {
                let branch = selector.hasPrefix("@branch:") ? String(selector.dropFirst(8)) : selector
                matches = worktrees.filter {
                    $0.path.path == canonicalPath(URL(fileURLWithPath: selector)).path
                        || $0.path.lastPathComponent == selector
                        || $0.branch == branch
                }
            }
        } else {
            matches = []
        }
        guard matches.count == 1, let match = matches.first else {
            let description = worktreeID ?? selector ?? ""
            throw MCPError.invalidParams("existing worktree selector is unknown or ambiguous: \(description)")
        }
        return match
    }

    private static func containingWorktree(
        for root: URL,
        in worktrees: [DirectHeadlessGitWorktree]
    ) -> DirectHeadlessGitWorktree? {
        worktrees
            .filter { relativeSuffix(of: root, within: $0.path) != nil }
            .max { $0.path.path.count < $1.path.path.count }
    }

    private static func routesAreEquivalent(
        _ lhs: DirectHeadlessInitialRoute,
        _ rhs: DirectHeadlessInitialRoute
    ) -> Bool {
        let lhsActiveRoot = lhs.rootOverlay.activeRoot.map { canonicalPath($0).path }
        let rhsActiveRoot = rhs.rootOverlay.activeRoot.map { canonicalPath($0).path }
        guard Set(lhs.bindingWorkingDirectories.map { canonicalPath($0).path })
            == Set(rhs.bindingWorkingDirectories.map { canonicalPath($0).path }),
            lhsActiveRoot == rhsActiveRoot,
            lhs.rootOverlay.mappings.count == rhs.rootOverlay.mappings.count
        else { return false }
        let lhsMappings = lhs.rootOverlay.mappings.sorted { $0.canonicalRoot.path < $1.canonicalRoot.path }
        let rhsMappings = rhs.rootOverlay.mappings.sorted { $0.canonicalRoot.path < $1.canonicalRoot.path }
        return lhsMappings == rhsMappings
    }

    private static func relativeSuffix(of child: URL, within parent: URL) -> String? {
        let childPath = canonicalPath(child).path
        let parentPath = canonicalPath(parent).path
        if childPath == parentPath { return "" }
        guard childPath.hasPrefix(parentPath + "/") else { return nil }
        return String(childPath.dropFirst(parentPath.count + 1))
    }

    private struct PorcelainRecord {
        let path: String
        let head: String?
        let branch: String?
    }

    private static func porcelainRecords(_ output: String) -> [PorcelainRecord] {
        output.split(separator: "\n\n").compactMap { block in
            var path: String?
            var head: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
            }
            return path.map { PorcelainRecord(path: $0, head: head, branch: branch) }
        }
    }

    private static func gitURL(root: URL, arguments: [String]) async throws -> URL {
        let raw = try await DirectProcess.run("/usr/bin/git", arguments: ["-C", root.path] + arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw, isDirectory: true)
            : root.appendingPathComponent(raw, isDirectory: true)
        return canonicalPath(url)
    }

    private static func gitLayout(worktreeRoot: URL) -> (gitDirectory: URL, commonDirectory: URL)? {
        let dotGit = worktreeRoot.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = canonicalPath(dotGit)
        } else {
            guard let contents = smallMetadataString(at: dotGit),
                  let firstLine = contents.split(separator: "\n", maxSplits: 1).first,
                  firstLine.hasPrefix("gitdir:")
            else { return nil }
            let raw = firstLine.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            gitDirectory = canonicalPath(
                raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : worktreeRoot.appendingPathComponent(raw)
            )
        }
        let commonFile = gitDirectory.appendingPathComponent("commondir")
        guard let rawCommon = smallMetadataString(at: commonFile)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawCommon.isEmpty
        else { return (gitDirectory, gitDirectory) }
        let commonDirectory = canonicalPath(
            rawCommon.hasPrefix("/")
                ? URL(fileURLWithPath: rawCommon)
                : gitDirectory.appendingPathComponent(rawCommon)
        )
        return (gitDirectory, commonDirectory)
    }

    private static func verifyWorktree(_ worktree: DirectHeadlessGitWorktree) async throws {
        guard canonicalPath(worktree.path).path == worktree.path.path else {
            throw MCPError.invalidRequest(
                "selected worktree identity could not be verified: \(worktree.path.path)"
            )
        }
        let isInsideWorktree: String
        do {
            isInsideWorktree = try await DirectProcess.run(
                "/usr/bin/git",
                arguments: [
                    "-C", worktree.path.path,
                    "rev-parse", "--is-inside-work-tree"
                ]
            )
        } catch {
            throw MCPError.invalidRequest(
                "selected worktree identity could not be verified: \(worktree.path.path)"
            )
        }
        guard isInsideWorktree.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
              let layout = gitLayout(worktreeRoot: worktree.path)
        else {
            throw MCPError.invalidRequest(
                "selected worktree identity could not be verified: \(worktree.path.path)"
            )
        }
        let gitDirectory = layout.gitDirectory
        let commonDirectory = layout.commonDirectory
        let isMain = sameDirectoryIdentity(gitDirectory, commonDirectory)
        let stableComponent = isMain ? "main" : gitDirectory.path
        guard gitDirectory.path == worktree.gitDirectory.path,
              isMain == worktree.isMain,
              worktree.repositoryID == "gitrepo_\(sha256(commonDirectory.path))",
              worktree.worktreeID == "wt_\(sha256("\(worktree.repositoryID)\u{0}\(stableComponent)"))"
        else {
            throw MCPError.invalidRequest("selected worktree identity could not be verified: \(worktree.path.path)")
        }
    }

    private static func smallMetadataString(at url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= 4096
        else { return nil }
        var data = Data(count: 4097)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            var total = 0
            while total < buffer.count {
                let result = read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total
                )
                if result > 0 {
                    total += result
                } else if result == 0 {
                    break
                } else if errno != EINTR {
                    return -1
                }
            }
            return total
        }
        guard count > 0, count <= 4096 else { return nil }
        data.removeSubrange(count ..< data.count)
        return String(data: data, encoding: .utf8)
    }

    private static func sameDirectoryIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        let canonicalLHS = canonicalPath(lhs)
        let canonicalRHS = canonicalPath(rhs)
        if canonicalLHS.path == canonicalRHS.path { return true }
        var lhsMetadata = stat()
        var rhsMetadata = stat()
        guard stat(canonicalLHS.path, &lhsMetadata) == 0,
              stat(canonicalRHS.path, &rhsMetadata) == 0
        else { return false }
        return lhsMetadata.st_dev == rhsMetadata.st_dev
            && lhsMetadata.st_ino == rhsMetadata.st_ino
    }

    private static func isHexColor(_ value: String) -> Bool {
        guard value.count == 7, value.first == "#" else { return false }
        return UInt64(value.dropFirst(), radix: 16) != nil
    }

    private static func canonicalPath(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func slug(_ value: String) -> String {
        let components = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var result = components.joined(separator: "-").prefix(24).description
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result.ifEmpty("repo")
    }
}

private extension String {
    func ifEmpty(_ replacement: String) -> String {
        isEmpty ? replacement : self
    }
}
