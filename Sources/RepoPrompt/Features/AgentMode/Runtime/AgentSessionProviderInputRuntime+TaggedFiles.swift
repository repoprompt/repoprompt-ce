import Foundation
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionProviderInputRuntime {
    /// Ephemeral proof over existing command and resource authorities, not another admission store.
    final class Admission: Equatable {
        let isCurrent: @MainActor () -> Bool
        let ownsCleanup: @MainActor () -> Bool
        init(isCurrent: @escaping @MainActor () -> Bool, ownsCleanup: @escaping @MainActor () -> Bool) {
            self.isCurrent = isCurrent
            self.ownsCleanup = ownsCleanup
        }

        nonisolated static func == (lhs: Admission, rhs: Admission) -> Bool {
            lhs === rhs
        }
    }

    struct ProviderMessage {
        let text: String
        var failures: [ExplicitFileFailure] = []
        /// Runtime-composed input retains the exact command/resource proof through provider awaits.
        /// Legacy/local assembly has no additional resource receipt beyond its existing fences.
        var dispatchIsCurrent: @MainActor () -> Bool = { true }
    }

    struct ExplicitFileFailure: Equatable {
        let attachment: AgentTaggedFileAttachment
        let reason: String

        var message: String {
            "Attached file \(attachment.relativePath.debugDescription) could not be included: \(reason)"
        }
    }

    /// Immutable input preparation. Reading files has no composer or transcript side effects.
    struct TaggedFileAugmentation {
        let text: String
        let includedPaths: [String]
        let failures: [ExplicitFileFailure]

        var failureMessage: String? {
            guard !failures.isEmpty else { return nil }
            return failures.map(\.message).joined(separator: "\n")
        }

        var warningText: String {
            guard let failureMessage else { return text }
            return text + "\n\n" + failureMessage + "\nDo not assume the omitted files' contents."
        }
    }

    static func recordTaggedFileFailures(_ failures: [ExplicitFileFailure], session: AgentTabSession, scope: AgentSessionRuntimeStore.Scope) {
        guard !failures.isEmpty, scope.sessions[session.tabID] === session, !scope.hasReleasedWriterClaims else { return }
        session.appendItem(.system(failures.map(\.message).joined(separator: "\n"), sequenceIndex: session.nextSequenceIndex))
        session.isDirty = true
        scope.persistence.scheduleSave(for: session)
        scope.presentation.requestUIRefresh(for: session, urgent: true)
    }

    private struct TaggedPathRequest {
        let path: String
        var attachments: [AgentTaggedFileAttachment]
    }

    /// Explicit provenance survives both path and resolved-file deduplication. Inferred paths
    /// retain their historical order and best-effort policy, including the budget's stop-at-first-overflow rule.
    static func prepareTaggedFileContents(
        _ text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment],
        context: Context?,
        tokenBudget: Int = AgentSessionProviderInputRuntime.taggedFileContentsTokenBudget,
        maxFiles: Int = AgentSessionProviderInputRuntime.taggedFileContentsMaxFiles,
        inferredPaths: [String]? = nil
    ) async -> TaggedFileAugmentation {
        var requests: [TaggedPathRequest] = []
        var indices: [String: Int] = [:]
        func add(_ path: String, attachment: AgentTaggedFileAttachment?) {
            let normalized = unescapeTaggedPath(path)
            if let index = indices[normalized] {
                if let attachment { requests[index].attachments.append(attachment) }
            } else {
                indices[normalized] = requests.count
                requests.append(.init(path: normalized, attachments: attachment.map { [$0] } ?? []))
            }
        }
        // Explicit attachments own the available budget. Guessed prose paths only use what
        // remains and never make a deliberate attachment fail. The XML marker gates guesses only.
        for attachment in taggedFileAttachments {
            add(attachment.relativePath, attachment: attachment)
        }
        if !text.contains("<file_contents>") {
            for path in inferredPaths ?? extractTaggedPaths(from: text) {
                add(path, attachment: nil)
            }
        }
        guard !requests.isEmpty else { return .init(text: text, includedPaths: [], failures: []) }
        guard let context else {
            return .init(text: text, includedPaths: [], failures: requests.flatMap { request in
                request.attachments.map { .init(attachment: $0, reason: "workspace content is unavailable") }
            })
        }
        let store = context.store
        let lookup = context.lookup
        let service = WorkspaceReadableFileService(store: store)
        let roots = await store.rootRefs(scope: lookup.rootScope)
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let displayRoots = lookup.bindingProjection?.visibleLogicalRootRefs ?? roots
        var failures: [ExplicitFileFailure] = []
        var blocks: [String] = []
        var included: [String] = []
        // Outcome by physical identity: aliases of an included file are not omissions; aliases
        // of an unreadable or over-budget file inherit the same honest failure.
        var outcomes: [String: String] = [:] // empty reason means included
        var admittedFiles = 0
        var tokens = 0
        var inferredBudgetExhausted = false
        let budgetFailure = "the \(tokenBudget)-token attachment budget was reached"
        for request in requests {
            func fail(_ reason: String) {
                failures.append(contentsOf: request.attachments.map { .init(attachment: $0, reason: reason) })
            }
            var resolvedKey: String?
            do {
                let resolution = try await service.resolveReadFileRequest(
                    lookup.translateInputPath(request.path), rootScope: lookup.rootScope
                )
                let key: String
                switch resolution {
                case let .workspace(match): key = "workspace:\(match.file.id)"
                case let .external(file): key = "external:\(file.absolutePath)"
                case let .issue(issue): fail(PathResolutionIssueRenderer.message(for: issue))
                    continue
                case .folder: fail("the path is a folder, not a file")
                    continue
                case .noCandidate: fail("the file is missing or is not readable in the current workspace")
                    continue
                }
                resolvedKey = key
                if let reason = outcomes[key] {
                    if reason.isEmpty { included.append(request.path) } else { fail(reason) }
                    continue
                }
                // Account for every excluded attachment without opening content that cannot
                // fit. Resolution still deduplicates aliases of already-included files above.
                if inferredBudgetExhausted {
                    outcomes[key] = budgetFailure
                    fail(budgetFailure)
                    continue
                }
                guard admittedFiles < maxFiles else {
                    let reason = "the \(maxFiles)-file attachment limit was reached"
                    outcomes[key] = reason
                    fail(reason)
                    continue
                }
                let block: String
                switch resolution {
                case let .workspace(match):
                    let file = match.file
                    guard let root = rootsByID[file.rootID],
                          let content = try await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath)
                    else {
                        let reason = "file content is unavailable"
                        outcomes[key] = reason
                        fail(reason)
                        continue
                    }
                    let entry = ResolvedPromptFileEntry(
                        file: file,
                        isCodemap: false,
                        mode: .fullFile,
                        loadedContent: content,
                        rootFolderPath: root.standardizedFullPath
                    )
                    block = PromptPackagingService.generateFileBlocksDetailed(
                        files: [entry], filePathDisplay: .relative, codemapPresentation: .empty,
                        displayPathResolver: { entry in
                            if let projected = lookup.bindingProjection?.projectedLogicalPathComponents(forPhysicalPath: entry.file.standardizedFullPath) {
                                return ClientPathFormatter.nonAbsoluteDisplayPath(root: projected.root, relativePath: projected.relativePath, visibleRoots: displayRoots)
                            }
                            return ClientPathFormatter.nonAbsoluteDisplayPath(root: root, relativePath: file.standardizedRelativePath, visibleRoots: displayRoots)
                        }
                    ).first?.text ?? ""
                case let .external(file):
                    let content = try await service.readAlwaysReadableExternalFile(file)
                    block = externalTaggedFileBlock(displayPath: file.displayPath, content: content)
                default: continue
                }
                guard !block.isEmpty else {
                    let reason = "file content could not be packaged"
                    outcomes[key] = reason
                    fail(reason)
                    continue
                }
                let blockTokens = TokenCalculationService.estimateTokens(for: block)
                guard tokens + blockTokens <= tokenBudget else {
                    // Explicit attachments are independent admission requests: a later smaller
                    // file may still fit. Only inferred paths keep stop-at-first-overflow.
                    if request.attachments.isEmpty { inferredBudgetExhausted = true }
                    outcomes[key] = budgetFailure
                    fail(budgetFailure)
                    continue
                }
                admittedFiles += 1
                tokens += blockTokens
                blocks.append(block)
                included.append(request.path)
                outcomes[key] = ""
            } catch {
                let reason = (error as? PathResolutionIssue).map(PathResolutionIssueRenderer.message(for:)) ?? error.localizedDescription
                if let resolvedKey { outcomes[resolvedKey] = reason }
                fail(reason)
            }
        }
        let xml = blocks.isEmpty ? "" : "<file_contents>\n\(blocks.joined(separator: "\n\n"))\n</file_contents>"
        let augmented = xml.isEmpty ? text : (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? xml : text + "\n\n" + xml)
        return .init(text: augmented, includedPaths: included, failures: failures)
    }
}
