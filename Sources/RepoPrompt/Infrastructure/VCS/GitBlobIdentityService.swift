import CryptoKit
import Darwin
import Foundation

struct GitBlobIdentityServiceHooks {
    var afterGitCollection: @Sendable () async -> Void
    var afterPathSecurityComponentOpen: @Sendable (String) -> Void = { _ in }

    static let none = GitBlobIdentityServiceHooks(afterGitCollection: {})
}

actor GitBlobIdentityService {
    private struct Attempt {
        let batch: GitBlobIdentityBatch
        let unstable: Bool
    }

    private enum PathSecurityState {
        case regular(GitBlobLStatFingerprint)
        case missing
        case symlinkLeaf(GitBlobLStatFingerprint)
        case symlinkComponent
        case nonRegular(GitBlobLStatFingerprint)
        case repositoryBoundary(GitBlobLStatFingerprint?)
    }

    private let gitService: GitService
    private let hooks: GitBlobIdentityServiceHooks
    private var eligibleOpportunityCount: UInt64 = 0
    private var digestMatchCount: UInt64 = 0
    private var digestMismatchCount: UInt64 = 0

    init(
        gitService: GitService = GitService(),
        hooks: GitBlobIdentityServiceHooks = .none
    ) {
        self.gitService = gitService
        self.hooks = hooks
    }

    func classify(
        workspaceRoot: URL,
        relativePaths: [String]
    ) async -> GitBlobIdentityBatch {
        guard Self.isBoundedBatch(relativePaths) else { return oversizedBatch() }

        let first = await classifyAttempt(workspaceRoot: workspaceRoot, relativePaths: relativePaths)
        guard first.unstable else { return first.batch }
        let second = await classifyAttempt(workspaceRoot: workspaceRoot, relativePaths: relativePaths)
        return GitBlobIdentityBatch(
            objectFormat: second.batch.objectFormat,
            classifications: second.batch.classifications,
            retriedAfterInstability: true
        )
    }

    /// Shadow-only validation. It consumes a caller's single securely validated raw buffer and
    /// never installs a locator or artifact. This deliberately remains disconnected from serving.
    func shadowValidate(
        classification: GitBlobIdentityClassification,
        validatedWorktreeBytes: Data
    ) -> GitBlobShadowValidationResult {
        guard case let .oidEligible(oid) = classification.outcome else { return .notEligible }
        eligibleOpportunityCount &+= 1
        let header = Data("blob \(validatedWorktreeBytes.count)\0".utf8)
        var input = Data(capacity: header.count + validatedWorktreeBytes.count)
        input.append(header)
        input.append(validatedWorktreeBytes)
        let actual: String = switch oid.objectFormat {
        case .sha1:
            Insecure.SHA1.hash(data: input).map { String(format: "%02x", $0) }.joined()
        case .sha256:
            SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        }
        if actual == oid.lowercaseHex {
            digestMatchCount &+= 1
            return .match
        }
        digestMismatchCount &+= 1
        return .mismatch
    }

    func shadowDiagnostics() -> GitBlobShadowDiagnostics {
        GitBlobShadowDiagnostics(
            eligibleOpportunityCount: eligibleOpportunityCount,
            digestMatchCount: digestMatchCount,
            digestMismatchCount: digestMismatchCount
        )
    }

    private func classifyAttempt(
        workspaceRoot: URL,
        relativePaths: [String]
    ) async -> Attempt {
        let workspaceRoot = workspaceRoot.standardizedFileURL
        let pathValidity = relativePaths.map(Self.isValidRelativePath)
        guard pathValidity.contains(true) else {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .invalidPath), unstable: false)
        }

        let layout: GitRepositoryLayout
        do {
            guard let resolved = try await gitService.resolveGitBlobRepository(containing: workspaceRoot) else {
                return classifyNonGit(
                    workspaceRoot: workspaceRoot,
                    relativePaths: relativePaths,
                    validity: pathValidity
                )
            }
            layout = resolved
        } catch GitBlobIdentityError.invalidObjectFormat {
            return Attempt(
                batch: unsupportedBatch(paths: relativePaths, reason: .invalidObjectFormat),
                unstable: false
            )
        } catch GitBlobIdentityError.unsupportedGit {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .unsupportedGit), unstable: false)
        } catch {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .unsupportedGit), unstable: false)
        }

        guard let rootPrefix = Self.repositoryPrefix(
            workspaceRoot: workspaceRoot,
            repositoryRoot: layout.workTreeRoot.standardizedFileURL
        ) else {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .invalidPath), unstable: false)
        }

        let repositoryPaths: [String?] = zip(relativePaths, pathValidity).map { path, valid in
            guard valid else { return nil }
            return rootPrefix.isEmpty ? path : "\(rootPrefix)/\(path)"
        }
        let requestedRepositoryPaths = repositoryPaths.compactMap(\.self)
        let preSecurity = relativePaths.map { path in
            pathSecurityState(workspaceRoot: workspaceRoot, relativePath: path)
        }
        let preFileFingerprints = preSecurity.map(Self.fingerprint)
        let preMetadata = Self.repositoryMetadataFingerprint(
            layout: layout,
            repositoryRelativePaths: requestedRepositoryPaths
        )
        let preLayout = Self.repositoryLayoutFingerprint(layout)
        let preIndexFingerprint = Self.lstatFingerprint(at: layout.gitDir.appendingPathComponent("index"))

        let objectFormat: GitObjectFormat
        let preConfiguration: GitBlobCheckoutConfiguration
        let preAttributes: [String: GitBlobPathAttributes]
        let indexEntries: [GitBlobIndexEntry]
        let statusRecords: [GitPorcelainV2PathRecord]
        do {
            objectFormat = try await gitService.gitBlobObjectFormat(at: layout.workTreeRoot)
            preConfiguration = try await gitService.gitBlobCheckoutConfiguration(at: layout.workTreeRoot)
            preAttributes = try await gitService.gitBlobAttributes(
                at: layout.workTreeRoot,
                repositoryRelativePaths: requestedRepositoryPaths
            )
            indexEntries = try await gitService.gitBlobIndexEntries(
                at: layout.workTreeRoot,
                repositoryRelativePaths: requestedRepositoryPaths
            )
            statusRecords = try await gitService.gitBlobStatusRecords(
                at: layout.workTreeRoot,
                repositoryRelativePaths: requestedRepositoryPaths
            )
        } catch GitBlobIdentityError.invalidObjectFormat {
            return Attempt(
                batch: unsupportedBatch(paths: relativePaths, reason: .invalidObjectFormat),
                unstable: false
            )
        } catch GitBlobIdentityError.unsupportedGit {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .unsupportedGit), unstable: false)
        } catch {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .unsupportedGit), unstable: false)
        }

        await hooks.afterGitCollection()
        if Task.isCancelled {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .unsupportedGit), unstable: false)
        }

        let postLayout: GitRepositoryLayout?
        do {
            postLayout = try await gitService.resolveGitBlobRepository(containing: workspaceRoot)
        } catch {
            postLayout = nil
        }

        let postConfiguration: GitBlobCheckoutConfiguration
        let postAttributes: [String: GitBlobPathAttributes]
        do {
            postConfiguration = try await gitService.gitBlobCheckoutConfiguration(at: layout.workTreeRoot)
            postAttributes = try await gitService.gitBlobAttributes(
                at: layout.workTreeRoot,
                repositoryRelativePaths: requestedRepositoryPaths
            )
        } catch {
            return Attempt(batch: unsupportedBatch(paths: relativePaths, reason: .unsupportedGit), unstable: true)
        }

        let postSecurity = relativePaths.map { path in
            pathSecurityState(workspaceRoot: workspaceRoot, relativePath: path)
        }
        let postFileFingerprints = postSecurity.map(Self.fingerprint)
        let postMetadata = postLayout.map {
            Self.repositoryMetadataFingerprint(
                layout: $0,
                repositoryRelativePaths: requestedRepositoryPaths
            )
        } ?? "<unresolved>"
        let postIndexFingerprint = postLayout.flatMap {
            Self.lstatFingerprint(at: $0.gitDir.appendingPathComponent("index"))
        }
        let postLayoutDigest = Self.repositoryLayoutFingerprint(postLayout)
        let preSemantic = Self.semanticDigest(
            objectFormat: objectFormat,
            configuration: preConfiguration,
            attributes: requestedRepositoryPaths.map { preAttributes[$0] ?? .unspecified }
        )
        let postSemantic = Self.semanticDigest(
            objectFormat: objectFormat,
            configuration: postConfiguration,
            attributes: requestedRepositoryPaths.map { postAttributes[$0] ?? .unspecified }
        )
        let preRepositoryToken = GitBlobRepositoryValidationToken(
            indexFingerprint: preIndexFingerprint,
            layoutSHA256: preLayout,
            metadataSHA256: preMetadata,
            semanticSHA256: preSemantic
        )
        let postRepositoryToken = GitBlobRepositoryValidationToken(
            indexFingerprint: postIndexFingerprint,
            layoutSHA256: postLayoutDigest,
            metadataSHA256: postMetadata,
            semanticSHA256: postSemantic
        )

        let entriesByPath = Dictionary(grouping: indexEntries, by: \.path)
        let recordsByPath = Dictionary(grouping: statusRecords, by: \.path).mapValues { $0.last! }
        var unstable = preRepositoryToken != postRepositoryToken
        let classifications = relativePaths.indices.map { index -> GitBlobIdentityClassification in
            guard pathValidity[index], let repositoryPath = repositoryPaths[index] else {
                return Self.invalidPathClassification(relativePaths[index])
            }
            let tokens = GitBlobValidationTokens(
                preRepository: preRepositoryToken,
                postRepository: postRepositoryToken,
                preWorktree: preFileFingerprints[index],
                postWorktree: postFileFingerprints[index]
            )
            if !tokens.isStable { unstable = true }
            let entries = (entriesByPath[repositoryPath] ?? []).sorted { $0.stage < $1.stage }
            let record = recordsByPath[repositoryPath]
            let attributes = preAttributes[repositoryPath] ?? .unspecified
            let materialization = Self.checkoutMaterialization(
                attributes: attributes,
                configuration: preConfiguration
            )
            return Self.makeClassification(
                relativePath: relativePaths[index],
                repositoryPath: repositoryPath,
                objectFormat: objectFormat,
                entries: entries,
                record: record,
                attributes: attributes,
                configuration: preConfiguration,
                materialization: materialization,
                security: postSecurity[index],
                tokens: tokens
            )
        }
        return Attempt(
            batch: GitBlobIdentityBatch(
                objectFormat: objectFormat,
                classifications: classifications,
                retriedAfterInstability: false
            ),
            unstable: unstable
        )
    }

    private func classifyNonGit(
        workspaceRoot: URL,
        relativePaths: [String],
        validity: [Bool]
    ) -> Attempt {
        let classifications = relativePaths.indices.map { index -> GitBlobIdentityClassification in
            guard validity[index] else { return Self.invalidPathClassification(relativePaths[index]) }
            let security = pathSecurityState(
                workspaceRoot: workspaceRoot,
                relativePath: relativePaths[index]
            )
            let fingerprint = Self.fingerprint(security)
            let outcome: GitBlobIdentityOutcome = switch security {
            case .regular:
                .requiresValidatedWorktreeBytes(.nonGit)
            case .missing:
                .unavailable(.missing)
            case .symlinkLeaf:
                .securityExcluded(.symlinkLeaf)
            case .symlinkComponent:
                .securityExcluded(.symlinkPathComponent)
            case .nonRegular:
                .unsupported(.nonRegularFile)
            case .repositoryBoundary:
                .unavailable(.repositoryUnavailable)
            }
            return GitBlobIdentityClassification(
                relativePath: relativePaths[index],
                repositoryRelativePath: nil,
                objectFormat: nil,
                indexEntries: [],
                porcelainRecord: nil,
                intentToAdd: false,
                hasConflictStages: false,
                skipWorktree: false,
                assumeUnchanged: false,
                attributes: nil,
                checkoutConfiguration: nil,
                checkoutMaterialization: nil,
                validationTokens: GitBlobValidationTokens(
                    preRepository: nil,
                    postRepository: nil,
                    preWorktree: fingerprint,
                    postWorktree: fingerprint
                ),
                outcome: outcome
            )
        }
        return Attempt(
            batch: GitBlobIdentityBatch(
                objectFormat: nil,
                classifications: classifications,
                retriedAfterInstability: false
            ),
            unstable: false
        )
    }

    private static func makeClassification(
        relativePath: String,
        repositoryPath: String,
        objectFormat: GitObjectFormat,
        entries: [GitBlobIndexEntry],
        record: GitPorcelainV2PathRecord?,
        attributes: GitBlobPathAttributes,
        configuration: GitBlobCheckoutConfiguration,
        materialization: GitBlobCheckoutMaterialization,
        security: PathSecurityState,
        tokens: GitBlobValidationTokens
    ) -> GitBlobIdentityClassification {
        let stageZero = entries.first { $0.stage == 0 }
        let hasConflictStages = entries.contains { $0.stage != 0 } || record?.kind == .unmerged
        let skipWorktree = entries.contains(where: \.skipWorktree)
        let assumeUnchanged = entries.contains(where: \.assumeUnchanged)
        let zeroOID = String(repeating: "0", count: objectFormat.oidHexCount)
        let intentToAdd = record?.indexOID == zeroOID &&
            stageZero != nil && record?.kind == .ordinary

        let outcome: GitBlobIdentityOutcome = if let stageZero, stageZero.isGitlink {
            .unsupported(.gitlink)
        } else if let stageZero, stageZero.isSymlink {
            .securityExcluded(.symlinkLeaf)
        } else {
            switch security {
            case .symlinkLeaf:
                .securityExcluded(.symlinkLeaf)
            case .symlinkComponent:
                .securityExcluded(.symlinkPathComponent)
            case .nonRegular:
                .unsupported(.nonRegularFile)
            case .repositoryBoundary:
                .unavailable(.repositoryUnavailable)
            case .missing:
                if skipWorktree, stageZero != nil {
                    .unavailable(.sparseAbsent)
                } else {
                    .unavailable(.missing)
                }
            case .regular:
                if hasConflictStages {
                    .requiresValidatedWorktreeBytes(.unmerged)
                } else if intentToAdd {
                    .requiresValidatedWorktreeBytes(.intentToAdd)
                } else if let stageZero, !stageZero.isRegularFile {
                    .unsupported(.unknownIndexMode)
                } else if skipWorktree || assumeUnchanged {
                    .requiresValidatedWorktreeBytes(.indexFlag)
                } else if !tokens.isStable {
                    .requiresValidatedWorktreeBytes(.changedDuringClassification)
                } else if case .requiresValidatedWorktreeBytes = materialization {
                    .requiresValidatedWorktreeBytes(.checkoutTransformation)
                } else if record?.kind == .untracked {
                    .requiresValidatedWorktreeBytes(.untracked)
                } else if record?.kind == .ignored {
                    .requiresValidatedWorktreeBytes(.ignored)
                } else if record?.hasWorkTreeChange == true, record?.hasIndexChange == true {
                    .requiresValidatedWorktreeBytes(.stagedAndUnstaged)
                } else if record?.hasWorkTreeChange == true {
                    .requiresValidatedWorktreeBytes(.dirty)
                } else if let stageZero {
                    oidOutcome(entry: stageZero, objectFormat: objectFormat)
                } else {
                    .requiresValidatedWorktreeBytes(.generatedOrExplicit)
                }
            }
        }

        return GitBlobIdentityClassification(
            relativePath: relativePath,
            repositoryRelativePath: repositoryPath,
            objectFormat: objectFormat,
            indexEntries: entries,
            porcelainRecord: record,
            intentToAdd: intentToAdd,
            hasConflictStages: hasConflictStages,
            skipWorktree: skipWorktree,
            assumeUnchanged: assumeUnchanged,
            attributes: attributes,
            checkoutConfiguration: configuration,
            checkoutMaterialization: materialization,
            validationTokens: tokens,
            outcome: outcome
        )
    }

    private static func oidOutcome(
        entry: GitBlobIndexEntry,
        objectFormat: GitObjectFormat
    ) -> GitBlobIdentityOutcome {
        guard let oid = try? GitBlobOID(objectFormat: objectFormat, lowercaseHex: entry.oid) else {
            return .unsupported(.unsupportedGit)
        }
        return .oidEligible(oid)
    }

    private static func checkoutMaterialization(
        attributes: GitBlobPathAttributes,
        configuration: GitBlobCheckoutConfiguration
    ) -> GitBlobCheckoutMaterialization {
        var reasons: [GitBlobCheckoutTransformReason] = []
        if case .set = attributes.text { reasons.append(.textAttribute) }
        if case .set = attributes.eol { reasons.append(.eolAttribute) }
        if let value = configuration.coreAutoCRLF, value != "false" {
            reasons.append(.coreAutoCRLF)
        }
        if let value = configuration.coreEOL, value != "native" {
            reasons.append(.coreEOL)
        }
        switch attributes.filter {
        case let .set(filter):
            reasons.append(.filterAttribute)
            if filter.lowercased() == "lfs" {
                reasons.append(.lfsFilter)
            }
            let prefix = "filter.\(filter.lowercased())."
            if !configuration.filterDriverConfiguration.keys.contains(where: { $0.hasPrefix(prefix) }) {
                reasons.append(.unknownFilterDriver)
            }
        case .unset:
            // `git check-attr` renders both `-filter` and literal `filter=unset` as
            // `unset`. A configured driver with that reserved name makes the result
            // ambiguous, so require validated worktree bytes rather than assuming
            // the disabling syntax was used.
            if configuration.filterDriverConfiguration.keys.contains(where: { $0.hasPrefix("filter.unset.") }) {
                reasons.append(.filterAttribute)
            }
        case .unspecified:
            break
        }
        if case .set = attributes.ident { reasons.append(.identAttribute) }
        if case .set = attributes.workingTreeEncoding { reasons.append(.workingTreeEncoding) }
        return reasons.isEmpty ? .bytePreserving : .requiresValidatedWorktreeBytes(Array(Set(reasons)).sorted {
            $0.rawValue < $1.rawValue
        })
    }

    private func unsupportedBatch(
        paths: [String],
        reason: GitBlobUnsupportedReason
    ) -> GitBlobIdentityBatch {
        GitBlobIdentityBatch(
            objectFormat: nil,
            classifications: paths.map { path in
                var classification = Self.invalidPathClassification(path)
                if reason != .invalidPath {
                    classification = GitBlobIdentityClassification(
                        relativePath: path,
                        repositoryRelativePath: nil,
                        objectFormat: nil,
                        indexEntries: [],
                        porcelainRecord: nil,
                        intentToAdd: false,
                        hasConflictStages: false,
                        skipWorktree: false,
                        assumeUnchanged: false,
                        attributes: nil,
                        checkoutConfiguration: nil,
                        checkoutMaterialization: nil,
                        validationTokens: classification.validationTokens,
                        outcome: .unsupported(reason)
                    )
                }
                return classification
            },
            retriedAfterInstability: false
        )
    }

    private func oversizedBatch() -> GitBlobIdentityBatch {
        GitBlobIdentityBatch(
            objectFormat: nil,
            classifications: [],
            retriedAfterInstability: false,
            failure: .batchTooLarge
        )
    }

    private static func isBoundedBatch(_ paths: [String]) -> Bool {
        guard !paths.isEmpty, paths.count <= 256 else { return false }
        var bytes = 0
        for path in paths {
            let count = path.utf8.count
            guard count <= 256 * 1024 - bytes else { return false }
            bytes += count
        }
        return true
    }

    private static func invalidPathClassification(_ path: String) -> GitBlobIdentityClassification {
        GitBlobIdentityClassification(
            relativePath: path,
            repositoryRelativePath: nil,
            objectFormat: nil,
            indexEntries: [],
            porcelainRecord: nil,
            intentToAdd: false,
            hasConflictStages: false,
            skipWorktree: false,
            assumeUnchanged: false,
            attributes: nil,
            checkoutConfiguration: nil,
            checkoutMaterialization: nil,
            validationTokens: GitBlobValidationTokens(
                preRepository: nil,
                postRepository: nil,
                preWorktree: nil,
                postWorktree: nil
            ),
            outcome: .unsupported(.invalidPath)
        )
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func repositoryPrefix(workspaceRoot: URL, repositoryRoot: URL) -> String? {
        let workspace = workspaceRoot.standardizedFileURL.path
        let repository = repositoryRoot.standardizedFileURL.path
        if workspace == repository { return "" }
        let prefix = repository.hasSuffix("/") ? repository : repository + "/"
        guard workspace.hasPrefix(prefix) else { return nil }
        return String(workspace.dropFirst(prefix.count))
    }

    private func pathSecurityState(
        workspaceRoot: URL,
        relativePath: String
    ) -> PathSecurityState {
        guard Self.isValidRelativePath(relativePath) else { return .missing }
        let components = relativePath.split(separator: "/").map(String.init)
        let rootDescriptor = open(
            workspaceRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { return .missing }
        var directoryDescriptor = rootDescriptor
        defer {
            if directoryDescriptor != rootDescriptor { close(directoryDescriptor) }
            close(rootDescriptor)
        }

        for (index, component) in components.enumerated() {
            var value = stat()
            guard fstatat(directoryDescriptor, component, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                return .missing
            }
            let fingerprint = Self.lstatFingerprint(value)
            let isLeaf = index == components.count - 1
            if fingerprint.isSymbolicLink {
                return isLeaf ? .symlinkLeaf(fingerprint) : .symlinkComponent
            }
            if isLeaf {
                return fingerprint.isRegularFile ? .regular(fingerprint) : .nonRegular(fingerprint)
            }
            guard (value.st_mode & S_IFMT) == S_IFDIR else { return .missing }
            let nextDescriptor = openat(
                directoryDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextDescriptor >= 0 else { return .missing }
            var repositoryMarker = stat()
            if fstatat(nextDescriptor, ".git", &repositoryMarker, AT_SYMLINK_NOFOLLOW) == 0 {
                let fingerprint = Self.lstatFingerprint(repositoryMarker)
                close(nextDescriptor)
                return .repositoryBoundary(fingerprint)
            }
            let markerError = errno
            guard markerError == ENOENT else {
                close(nextDescriptor)
                return .repositoryBoundary(nil)
            }
            if directoryDescriptor != rootDescriptor { close(directoryDescriptor) }
            directoryDescriptor = nextDescriptor
            hooks.afterPathSecurityComponentOpen(components[0 ... index].joined(separator: "/"))
        }
        return .missing
    }

    private static func fingerprint(_ state: PathSecurityState) -> GitBlobLStatFingerprint? {
        switch state {
        case let .regular(value), let .symlinkLeaf(value), let .nonRegular(value): value
        case let .repositoryBoundary(value): value
        case .missing, .symlinkComponent: nil
        }
    }

    private static func lstatFingerprint(at url: URL) -> GitBlobLStatFingerprint? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return lstatFingerprint(value)
    }

    private static func lstatFingerprint(_ value: stat) -> GitBlobLStatFingerprint {
        GitBlobLStatFingerprint(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private static func repositoryMetadataFingerprint(
        layout: GitRepositoryLayout,
        repositoryRelativePaths: [String]
    ) -> String {
        var urls = [
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("config"),
            layout.gitDir.appendingPathComponent("config.worktree"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
        for path in repositoryRelativePaths {
            let components = path.split(separator: "/").dropLast()
            var directory = layout.workTreeRoot
            urls.append(directory.appendingPathComponent(".gitattributes"))
            for component in components {
                directory.appendPathComponent(String(component))
                urls.append(directory.appendingPathComponent(".gitattributes"))
            }
        }
        var data = Data()
        for url in Dictionary(grouping: urls, by: { $0.standardizedFileURL.path }).keys.sorted() {
            append(fingerprint: lstatFingerprint(at: URL(fileURLWithPath: url)), to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func repositoryLayoutFingerprint(_ layout: GitRepositoryLayout?) -> String {
        guard let layout else {
            return SHA256.hash(data: Data("unresolved".utf8)).map { String(format: "%02x", $0) }.joined()
        }
        var data = Data()
        for url in [layout.dotGitPath, layout.gitDir, layout.commonDir] {
            data.append(Data(url.standardizedFileURL.path.utf8))
            data.append(0)
            append(fingerprint: lstatFingerprint(at: url), to: &data)
        }
        for url in [layout.dotGitPath, layout.gitDir.appendingPathComponent("commondir")] {
            guard let contents = try? Data(contentsOf: url), contents.count <= 4096 else {
                data.append(0)
                continue
            }
            data.append(1)
            data.append(contents)
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func semanticDigest(
        objectFormat: GitObjectFormat,
        configuration: GitBlobCheckoutConfiguration,
        attributes: [GitBlobPathAttributes]
    ) -> String {
        var lines = [
            objectFormat.rawValue,
            configuration.coreAutoCRLF ?? "<nil>",
            configuration.coreEOL ?? "<nil>"
        ]
        for key in configuration.filterDriverConfiguration.keys.sorted() {
            lines.append(key)
            lines.append(configuration.filterDriverConfiguration[key] ?? "")
        }
        for value in attributes {
            lines.append(contentsOf: [
                value.text.semanticValue,
                value.eol.semanticValue,
                value.filter.semanticValue,
                value.ident.semanticValue,
                value.workingTreeEncoding.semanticValue
            ])
        }
        return SHA256.hash(data: Data(lines.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(fingerprint: GitBlobLStatFingerprint?, to data: inout Data) {
        guard let fingerprint else {
            data.append(0)
            return
        }
        data.append(1)
        let values = [
            String(fingerprint.device), String(fingerprint.inode), String(fingerprint.mode),
            String(fingerprint.size), String(fingerprint.modificationSeconds),
            String(fingerprint.modificationNanoseconds), String(fingerprint.changeSeconds),
            String(fingerprint.changeNanoseconds)
        ]
        data.append(Data(values.joined(separator: ":").utf8))
        data.append(0)
    }
}
