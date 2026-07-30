import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class ToolOutputFormatterCodeStructureTests: XCTestCase {
    private static let root = "rp-agent-59d8d04e-feature-graph-native-codemaps-ab610f0c"
    private static let base = "Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/"

    func testCompleteFixtureMatchesMinimalGoldenOutput() throws {
        let text = try formatted(Self.completeFixture())

        XCTAssertEqual(text, """
        ## Code Structure ✅ — 1 seed + 1 related • 1 edge • signatures 2 files, 570 tokens
        - Root `\(Self.root)` — paths below are root-relative

        ### Signatures
        Base: `\(Self.base)`
        #### `ClaudeSDKProtocolCodec.swift` — seed • 411 tokens
        ```text
        Imports:
          - import Foundation
        ```
        #### `ClaudeProviderJSONValue.swift` — uses, depth 1 • 159 tokens
        ```text
        Enums:
          - ClaudeProviderJSONValue
        ```
        """)
        XCTAssertFalse(text.contains("- Result:"), text)
        XCTAssertFalse(text.contains("### Diagnostics"), text)
    }

    func testPartialFixtureUsesSingleSemanticConvergenceClause() throws {
        let text = try formatted(Self.partialFixture())

        XCTAssertEqual(text, """
        ## Code Structure ⚠️ partial — a retry may return more relationships
        - Result: 1 seed + 1 related • 1 edge • signatures 2 files, 570 tokens
        - Root `\(Self.root)` — paths below are root-relative

        ### Signatures
        Base: `\(Self.base)`
        #### `ClaudeSDKProtocolCodec.swift` — seed • 411 tokens
        ```text
        Imports:
          - import Foundation
        ```
        #### `ClaudeProviderJSONValue.swift` — uses, depth 1 • 159 tokens
        ```text
        Enums:
          - ClaudeProviderJSONValue
        ```
        """)
        XCTAssertFalse(text.contains("### Diagnostics"), text)
    }

    func testPendingAndUnavailableFixturesUseExactSemanticRecovery() throws {
        let pending = try formatted(Self.pendingFixture())
        let unavailable = try formatted(Self.unavailableFixture())

        XCTAssertEqual(pending, """
        ## Code Structure ⏳ pending — `Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift` is not in the code graph yet
        - Retry shortly. If this persists, the file may be excluded or of an unsupported type.
        """)
        XCTAssertEqual(unavailable, """
        ## Code Structure ❌ unavailable — no requested path resolved
        - Requested: `Packages/Missing.swift`
        - Check spelling with get_file_tree, then retry root-relative or root-prefixed.
        """)
        XCTAssertFalse(pending.contains("- Result:"), pending)
        XCTAssertFalse(unavailable.contains("- Result:"), unavailable)

        let disabledIssue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "codemaps_disabled",
            phase: "graph_snapshot",
            path: nil,
            retryable: false,
            retryAfterMilliseconds: nil,
            attempted: nil,
            limit: nil,
            message: "Codemap generation is disabled."
        )
        let disabled = try formatted(Self.reply(
            status: .unavailable,
            roots: [],
            summary: .init(seeds: 0, nodes: 0, edges: 0, files: 0, tokens: 0),
            issues: [disabledIssue]
        ))
        XCTAssertEqual(disabled, """
        ## Code Structure ❌ unavailable — codemap generation is disabled
        - Enable codemaps, then retry.
        """)

        let unavailableIssue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "graph_revoked",
            phase: "graph_snapshot",
            path: nil,
            retryable: false,
            retryAfterMilliseconds: nil,
            attempted: nil,
            limit: nil,
            message: "The graph snapshot was revoked."
        )
        let generic = try formatted(Self.reply(
            status: .unavailable,
            roots: [],
            summary: .init(seeds: 0, nodes: 0, edges: 0, files: 0, tokens: 0),
            issues: [unavailableIssue]
        ))
        XCTAssertEqual(generic, """
        ## Code Structure ❌ unavailable — The graph snapshot was revoked
        - Resolve the reported issue, then retry.
        """)
    }

    func testSingleRootPathsRenderRootRelativeAndSharedBaseOnce() throws {
        let text = try formatted(Self.partialFixture())

        XCTAssertEqual(occurrences(of: Self.root, in: text), 1, text)
        XCTAssertEqual(occurrences(of: "Base: `\(Self.base)`", in: text), 1, text)
        XCTAssertFalse(text.contains("`\(Self.root)/\(Self.base)ClaudeSDKProtocolCodec.swift`"), text)
        XCTAssertTrue(text.contains("#### `ClaudeSDKProtocolCodec.swift`"), text)
    }

    func testSelfEdgesAndFreshnessTelemetryRemainInDTOButNotMarkdown() throws {
        let dto = Self.partialFixture()
        let text = try formatted(dto)
        let encoded = try JSONEncoder().encode(dto)
        let roundTripped = try JSONDecoder().decode(ToolResultDTOs.CodeStructureReplyDTO.self, from: encoded)

        XCTAssertEqual(roundTripped, dto)
        XCTAssertEqual(roundTripped.roots.first?.index.indexed, 256)
        XCTAssertEqual(roundTripped.roots.first?.index.total, 320)
        XCTAssertEqual(roundTripped.retry?.retryAfterMilliseconds, 100)
        XCTAssertEqual(roundTripped.roots.first?.unresolved.map(\.name), ["Encoder", "Data", "MissingType"])
        XCTAssertTrue(roundTripped.roots.first?.edges.contains(where: { $0.from == $0.to }) == true)
        XCTAssertEqual(dto.summary.edges, 2)
        XCTAssertTrue(text.contains("• 1 edge"), text)
        XCTAssertFalse(text.contains("ClaudeSDKProtocolCodec.swift` → `ClaudeSDKProtocolCodec.swift"), text)
    }

    func testSignatureModeOmitsGraphForTrivialEdgeAndStripsFileHeader() throws {
        let text = try formatted(Self.partialFixture())

        XCTAssertFalse(text.contains("#### Nodes"), text)
        XCTAssertFalse(text.contains("### Graph"), text)
        XCTAssertFalse(text.contains("File: "), text)
        XCTAssertTrue(text.contains("— seed • 411 tokens"), text)
        XCTAssertTrue(text.contains("— uses, depth 1 • 159 tokens"), text)

        let seedA = "Project/Sources/SeedA.swift"
        let seedB = "Project/Sources/SeedB.swift"
        let related = "Project/Sources/Related.swift"
        let attributed = Self.reply(
            status: .ok,
            roots: [Self.rootDTO(
                root: "Project",
                nodes: [
                    .init(path: seedA, depth: 0, seed: true, reachedBy: []),
                    .init(path: seedB, depth: 0, seed: true, reachedBy: []),
                    .init(path: related, depth: 1, seed: nil, reachedBy: ["uses"])
                ],
                edges: [.init(from: seedA, to: related, symbols: ["Related"], ambiguous: nil)],
                seeds: [
                    .init(path: seedA, state: .covered),
                    .init(path: seedB, state: .covered)
                ]
            )],
            files: [
                .init(path: seedA, role: "seed", depth: 0, reachedBy: [], content: "struct SeedA {}", tokens: 4),
                .init(path: seedB, role: "seed", depth: 0, reachedBy: [], content: "struct SeedB {}", tokens: 4),
                .init(path: related, role: "related", depth: 1, reachedBy: ["uses"], content: "struct Related {}", tokens: 4)
            ],
            summary: .init(seeds: 2, nodes: 3, edges: 1, files: 3, tokens: 12)
        )
        let attributedText = try formatted(attributed)
        XCTAssertTrue(attributedText.contains("### Graph"), attributedText)
        XCTAssertTrue(attributedText.contains("- `Sources/SeedA.swift` (seed) → uses:\n  - `Sources/Related.swift` — Related"), attributedText)
    }

    func testGraphOnlyModeRendersAdjacencyAndIsolatedSeeds() throws {
        let root = "Project"
        let dto = Self.reply(
            status: .ok,
            roots: [Self.rootDTO(
                root: root,
                nodes: [
                    .init(path: "Project/Sources/A.swift", depth: 0, seed: true, reachedBy: []),
                    .init(path: "Project/Sources/B.swift", depth: 1, seed: nil, reachedBy: ["uses"]),
                    .init(path: "Project/Sources/Isolated.swift", depth: 0, seed: true, reachedBy: [])
                ],
                edges: [.init(from: "Project/Sources/A.swift", to: "Project/Sources/B.swift", symbols: ["B"], ambiguous: nil)],
                seeds: [
                    .init(path: "Project/Sources/A.swift", state: .covered),
                    .init(path: "Project/Sources/Isolated.swift", state: .covered)
                ]
            )],
            summary: .init(seeds: 2, nodes: 3, edges: 1, files: 0, tokens: 0)
        )
        let text = try formatted(dto)

        XCTAssertTrue(text.contains("- `Sources/A.swift` (seed) → uses:\n  - `Sources/B.swift` — B"), text)
        XCTAssertTrue(text.contains("- `Sources/Isolated.swift` (seed) — no relationships returned"), text)
        XCTAssertFalse(text.contains("#### Nodes"), text)
    }

    func testUnknownIssueUsesPlainLanguageFallbackWithoutPhaseOrIssueBlock() throws {
        let issue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "relationship_data_incomplete",
            phase: "graph_snapshot",
            path: "Project/Sources/Seed.swift",
            retryable: false,
            retryAfterMilliseconds: nil,
            attempted: nil,
            limit: nil,
            message: "Additional relationship data could not be loaded."
        )
        let dto = Self.reply(
            status: .partial,
            roots: [Self.rootDTO(
                root: "Project",
                nodes: [.init(path: "Project/Sources/Seed.swift", depth: 0, seed: true, reachedBy: [])],
                seeds: [.init(path: "Project/Sources/Seed.swift", state: .covered)]
            )],
            summary: .init(seeds: 1, nodes: 1, edges: 0, files: 0, tokens: 0),
            issues: [issue]
        )
        let text = try formatted(dto)

        XCTAssertTrue(text.contains("### Diagnostics\n- Additional relationship data could not be loaded [`Sources/Seed.swift`]"), text)
        XCTAssertFalse(text.contains("relationship_data_incomplete"), text)
        XCTAssertFalse(text.contains("graph_snapshot"), text)
        XCTAssertFalse(text.contains("- Issues:"), text)
    }

    func testSmallSignatureSizeKeepsSeedAndReportsOmittedRelatedFile() throws {
        let seed = "Project/Sources/Seed.swift"
        let related = "Project/Sources/Related.swift"
        let issue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "signature_size_limit",
            phase: "render",
            path: nil,
            retryable: false,
            retryAfterMilliseconds: nil,
            attempted: nil,
            limit: nil,
            message: "Some signatures were omitted to fit the requested output size."
        )
        let root = Self.rootDTO(
            root: "Project",
            status: .partial,
            nodes: [
                .init(path: seed, depth: 0, seed: true, reachedBy: []),
                .init(path: related, depth: 1, seed: nil, reachedBy: ["uses"])
            ],
            edges: [.init(from: seed, to: related, symbols: ["Related"], ambiguous: nil)],
            seeds: [.init(path: seed, state: .covered)]
        )
        let file = ToolResultDTOs.CodeStructureReplyDTO.FileDTO(
            path: seed,
            role: "seed",
            depth: 0,
            reachedBy: [],
            content: "File: \(seed)\nstruct Seed {}",
            tokens: 10
        )
        let text = try formatted(Self.reply(
            status: .partial,
            roots: [root],
            files: [file],
            summary: .init(seeds: 1, nodes: 2, edges: 1, files: 1, tokens: 10),
            issues: [issue],
            size: .small
        ))

        XCTAssertTrue(text.contains("#### `Sources/Seed.swift` — seed • 10 tokens"), text)
        XCTAssertTrue(text.contains("- Omitted (1): `Sources/Related.swift` — rerun with size: medium"), text)
        XCTAssertEqual(occurrences(of: "rerun with size: medium", in: text), 1, text)
        XCTAssertFalse(text.contains("### Diagnostics"), text)
    }

    func testTruncationEmitsOneActionWithSizeLadder() throws {
        for (size, action) in [
            (WorkspaceCodemapGraphOutputSize.small, "rerun with size: medium"),
            (.medium, "rerun with size: large"),
            (.large, "narrow paths or reduce depth; size is already large")
        ] {
            let dto = Self.assembledTruncation(size: size)
            XCTAssertEqual(dto.roots.first?.issues.first?.code, "graph_size_limit")
            XCTAssertNil(dto.roots.first?.issues.first?.attempted)
            XCTAssertNil(dto.roots.first?.issues.first?.limit)
            let text = try formatted(dto)
            XCTAssertEqual(occurrences(of: action, in: text), 1, text)
            XCTAssertTrue(text.contains("Truncated: 12 files dropped"), text)
            XCTAssertFalse(text.contains("`graph_size_limit`"), text)
        }
    }

    func testMixedSeedFixtureReportsOnlyTheUncoveredSeedHole() throws {
        let covered = "Project/Sources/Covered.swift"
        let excluded = "Project/Sources/Generated.swift"
        let issue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "seed_excluded",
            phase: "graph_snapshot",
            path: excluded,
            retryable: false,
            retryAfterMilliseconds: nil,
            attempted: nil,
            limit: nil,
            message: "The seed is excluded."
        )
        let dto = Self.reply(
            status: .partial,
            roots: [Self.rootDTO(
                root: "Project",
                status: .partial,
                nodes: [.init(path: covered, depth: 0, seed: true, reachedBy: [])],
                seeds: [
                    .init(path: covered, state: .covered),
                    .init(path: excluded, state: .excluded)
                ],
                issues: [issue]
            )],
            summary: .init(seeds: 2, nodes: 1, edges: 0, files: 0, tokens: 0),
            issues: [issue]
        )
        let text = try formatted(dto)

        XCTAssertTrue(text.contains("- Seed `Sources/Generated.swift` returned nothing — excluded or unsupported type"), text)
        XCTAssertEqual(occurrences(of: "returned nothing", in: text), 1, text)
        XCTAssertFalse(text.contains("seed_excluded"), text)
    }

    func testMultiRootDeclaresEachRootOnceWithoutFreshnessDiagnostics() throws {
        let roots = [
            Self.rootDTO(
                root: "Alpha",
                status: .partial,
                index: .init(state: .indexing, indexed: 1, total: 2),
                nodes: [.init(path: "Alpha/A.swift", depth: 0, seed: true, reachedBy: [])]
            ),
            Self.rootDTO(root: "Beta", nodes: [.init(path: "Beta/B.swift", depth: 0, seed: true, reachedBy: [])])
        ]
        let text = try formatted(Self.reply(
            status: .partial,
            roots: roots,
            summary: .init(seeds: 2, nodes: 2, edges: 0, files: 0, tokens: 0),
            retry: .init(retryable: true, retryAfterMilliseconds: 100)
        ))

        XCTAssertTrue(text.contains("- Roots: 2 (1 ok, 1 partial)"), text)
        XCTAssertEqual(occurrences(of: "### Root `Alpha`", in: text), 1, text)
        XCTAssertEqual(occurrences(of: "### Root `Beta`", in: text), 1, text)
        XCTAssertFalse(text.contains("### Diagnostics"), text)
    }

    func testAllFormatterFixturesSuppressInternalTelemetryVocabulary() throws {
        let fixtures = [
            Self.completeFixture(),
            Self.partialFixture(),
            Self.pendingFixture(),
            Self.unavailableFixture(),
            Self.assembledTruncation(size: .small)
        ]
        let forbidden = ["Index:", "/320", "≈", "not_indexed", "Unresolved", "Internal refs", "Updates pending"]

        for dto in fixtures {
            let text = try formatted(dto)
            for term in forbidden {
                XCTAssertFalse(text.contains(term), "Unexpected \(term) in:\n\(text)")
            }
        }
    }

    func testLiveSampleFixturesRecordLineAndByteSavings() throws {
        for (name, dto) in [("partial", Self.partialFixture()), ("pending", Self.pendingFixture())] {
            let before = expandedReferenceFormatted(dto)
            let after = try formatted(dto)
            let beforeLines = before.components(separatedBy: "\n").count
            let afterLines = after.components(separatedBy: "\n").count
            let beforeBytes = before.utf8.count
            let afterBytes = after.utf8.count
            print("CODE_STRUCTURE_METRIC \(name) before_lines=\(beforeLines) after_lines=\(afterLines) before_bytes=\(beforeBytes) after_bytes=\(afterBytes)")
            XCTAssertLessThan(afterLines, beforeLines, name)
            XCTAssertLessThan(afterBytes, beforeBytes, name)
        }
    }

    private func formatted(_ dto: ToolResultDTOs.CodeStructureReplyDTO) throws -> String {
        let blocks = try ToolOutputFormatter.formatCodeStructure(value: Value(dto))
        guard blocks.count == 1, case let .text(text, _, _) = blocks[0] else {
            XCTFail("Expected one text block")
            return ""
        }
        return text
    }

    private func expandedReferenceFormatted(_ dto: ToolResultDTOs.CodeStructureReplyDTO) -> String {
        var out = [
            "## Code Structure ⚠️",
            "- **Status**: `\(dto.status.rawValue)`",
            "- **Roots**: \(dto.roots.count)",
            "- **Graph**: \(dto.summary.seeds) seeds • \(dto.summary.nodes) nodes • \(dto.summary.edges) edges",
            "- **Signatures**: \(dto.summary.files) files • \(dto.summary.tokens) tokens"
        ]
        for root in dto.roots {
            out.append("")
            out.append("### `\(root.root)` — \(root.status.rawValue)")
            out.append("- Index: \(root.index.state.rawValue) (\(root.index.indexed)/\(root.index.total))")
            if !root.issues.isEmpty {
                out.append("- Issues:")
                out.append(contentsOf: root.issues.map { "- `\($0.code)` (\($0.phase)): \($0.message)" })
            }
            if !root.seeds.isEmpty {
                out.append("- Seeds: " + root.seeds.map { "`\($0.path)` [\($0.state.rawValue)]" }.joined(separator: ", "))
            }
            if !root.nodes.isEmpty {
                out.append("")
                out.append("#### Nodes")
                out.append(contentsOf: root.nodes.map { "- `\($0.path)` — depth \($0.depth)" })
            }
            if !root.edges.isEmpty {
                out.append("")
                out.append("#### Edges")
                out.append(contentsOf: root.edges.map { "- `\($0.from)` → `\($0.to)` — \($0.symbols.joined(separator: ", "))" })
            }
            if !root.unresolved.isEmpty {
                out.append("")
                out.append("#### Unresolved")
                out.append(contentsOf: root.unresolved.map { "- `\($0.from)`: \($0.name) — \($0.reason.rawValue)" })
            }
        }
        if !dto.files.isEmpty {
            out.append("")
            out.append("### Signatures")
            for file in dto.files {
                out.append("#### `\(file.path)` — \(file.role), depth \(file.depth), \(file.tokens) tokens")
                out.append("```text\n\(file.content)\n```")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func completeFixture() -> ToolResultDTOs.CodeStructureReplyDTO {
        usefulFixture(status: .ok, indexing: false)
    }

    private static func partialFixture() -> ToolResultDTOs.CodeStructureReplyDTO {
        usefulFixture(status: .partial, indexing: true)
    }

    private static func usefulFixture(
        status: ToolResultDTOs.CodeStructureReplyDTO.Status,
        indexing: Bool
    ) -> ToolResultDTOs.CodeStructureReplyDTO {
        let codec = "\(root)/\(base)ClaudeSDKProtocolCodec.swift"
        let value = "\(root)/\(base)ClaudeProviderJSONValue.swift"
        let graphIssue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "graph_indexing",
            phase: "graph_snapshot",
            path: nil,
            retryable: true,
            retryAfterMilliseconds: 100,
            attempted: nil,
            limit: nil,
            message: "The committed graph is still indexing."
        )
        return Self.reply(
            status: status,
            roots: [Self.rootDTO(
                root: root,
                status: status,
                index: indexing ? .init(state: .indexing, indexed: 256, total: 320) : .init(state: .complete, indexed: 320, total: 320),
                updatesPending: indexing,
                nodes: [
                    .init(path: codec, depth: 0, seed: true, reachedBy: []),
                    .init(path: value, depth: 1, seed: nil, reachedBy: ["uses"])
                ],
                edges: [
                    .init(from: codec, to: codec, symbols: ["InboundMessage"], ambiguous: nil),
                    .init(from: codec, to: value, symbols: ["ClaudeProviderJSONValue"], ambiguous: nil)
                ],
                seeds: [.init(path: codec, state: .covered)],
                unresolved: [
                    .init(from: codec, name: "Encoder", reason: .notIndexedYet),
                    .init(from: codec, name: "Data", reason: .notIndexedYet),
                    .init(from: codec, name: "MissingType", reason: .missing)
                ],
                issues: indexing ? [graphIssue] : []
            )],
            files: [
                .init(path: codec, role: "seed", depth: 0, reachedBy: [], content: "File: \(codec)\nImports:\n  - import Foundation", tokens: 411),
                .init(path: value, role: "related", depth: 1, reachedBy: ["uses"], content: "File: \(value)\nEnums:\n  - ClaudeProviderJSONValue", tokens: 159)
            ],
            summary: .init(seeds: 1, nodes: 2, edges: 2, files: 2, tokens: 570),
            retry: indexing ? .init(retryable: true, retryAfterMilliseconds: 100) : nil
        )
    }

    private static func pendingFixture() -> ToolResultDTOs.CodeStructureReplyDTO {
        let path = "\(root)/Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift"
        let issue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "seed_not_indexed",
            phase: "graph_snapshot",
            path: path,
            retryable: true,
            retryAfterMilliseconds: 100,
            attempted: nil,
            limit: nil,
            message: "The seed is not yet present in the committed graph."
        )
        return Self.reply(
            status: .pending,
            roots: [Self.rootDTO(
                root: root,
                status: .pending,
                index: .init(state: .indexing, indexed: 448, total: 512),
                seeds: [.init(path: path, state: .notIndexed)],
                issues: [issue]
            )],
            summary: .init(seeds: 1, nodes: 0, edges: 0, files: 0, tokens: 0),
            retry: .init(retryable: true, retryAfterMilliseconds: 100)
        )
    }

    private static func unavailableFixture() -> ToolResultDTOs.CodeStructureReplyDTO {
        let path = "Packages/Missing.swift"
        let issue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO(
            code: "path_not_found",
            phase: "seed_resolution",
            path: path,
            retryable: false,
            retryAfterMilliseconds: nil,
            attempted: nil,
            limit: nil,
            message: "No requested path resolved to a file."
        )
        return Self.reply(
            status: .unavailable,
            roots: [],
            summary: .init(seeds: 0, nodes: 0, edges: 0, files: 0, tokens: 0),
            issues: [issue]
        )
    }

    private static func assembledTruncation(
        size: WorkspaceCodemapGraphOutputSize
    ) -> ToolResultDTOs.CodeStructureReplyDTO {
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let fileID = UUID()
        let path = "Project/Sources/App.swift"
        let root = WorkspaceCodemapStructureRootResult(
            rootEpoch: rootEpoch,
            rootDisplayName: "Project",
            status: .partial,
            coverage: nil,
            updatesPending: false,
            seeds: [.init(fileID: fileID, path: path, state: .covered)],
            nodes: [.init(fileID: fileID, path: path, depth: 0, isSeed: true, reachedBy: [])],
            edges: [],
            unresolved: [],
            truncation: .init(droppedNodeCount: 12),
            issues: [.init(
                code: "graph_size_limit",
                phase: "graph_traversal",
                path: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                attempted: nil,
                limit: nil,
                message: "Graph output was truncated to fit the requested output size."
            )],
            receipt: nil
        )
        return MCPServerViewModel.codeStructureReplyDTO(
            aggregate: .init(status: .partial, roots: [root], issues: []),
            presentation: nil,
            revalidation: [:],
            includesSignatures: false,
            budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(
                size: size,
                includesSignatures: false
            ),
            size: size,
            worktreeScope: nil
        )
    }

    private static func rootDTO(
        root: String,
        status: ToolResultDTOs.CodeStructureReplyDTO.Status = .ok,
        index: ToolResultDTOs.CodeStructureReplyDTO.IndexDTO = .init(state: .complete, indexed: 1, total: 1),
        updatesPending: Bool? = nil,
        nodes: [ToolResultDTOs.CodeStructureReplyDTO.NodeDTO] = [],
        edges: [ToolResultDTOs.CodeStructureReplyDTO.EdgeDTO] = [],
        seeds: [ToolResultDTOs.CodeStructureReplyDTO.SeedDTO] = [],
        unresolved: [ToolResultDTOs.CodeStructureReplyDTO.UnresolvedDTO] = [],
        truncated: ToolResultDTOs.CodeStructureReplyDTO.TruncatedDTO? = nil,
        issues: [ToolResultDTOs.CodeStructureReplyDTO.IssueDTO] = []
    ) -> ToolResultDTOs.CodeStructureReplyDTO.RootDTO {
        .init(
            root: root,
            status: status,
            index: index,
            updatesPending: updatesPending,
            seeds: seeds,
            nodes: nodes,
            edges: edges,
            unresolved: unresolved,
            truncated: truncated,
            issues: issues
        )
    }

    private static func reply(
        status: ToolResultDTOs.CodeStructureReplyDTO.Status,
        roots: [ToolResultDTOs.CodeStructureReplyDTO.RootDTO],
        files: [ToolResultDTOs.CodeStructureReplyDTO.FileDTO] = [],
        summary: ToolResultDTOs.CodeStructureReplyDTO.SummaryDTO,
        issues: [ToolResultDTOs.CodeStructureReplyDTO.IssueDTO] = [],
        retry: ToolResultDTOs.CodeStructureReplyDTO.RetryDTO? = nil,
        size: WorkspaceCodemapGraphOutputSize = .medium
    ) -> ToolResultDTOs.CodeStructureReplyDTO {
        .init(status: status, size: size, roots: roots, files: files, summary: summary, issues: issues, retry: retry, worktreeScope: nil)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
