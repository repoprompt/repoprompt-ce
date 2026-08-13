import Foundation
#if os(macOS)
    import Darwin
    import RepoPromptC
#endif

enum WorkspaceReadableFileResolution {
    case workspace(WorkspaceExactExistingFileMatch)
    case external(WorkspaceExternalReadableFile)
    case folder(displayPath: String)
    case issue(PathResolutionIssue)
    case noCandidate
}

struct WorkspaceReadableFileService {
    static let externalReadByteLimit = 10_000_000
    private static let externalReadChunkSize = 1_048_576

    let store: WorkspaceFileContextStore
    let homeDirectoryURL: URL
    let beforeExternalReadOpenForTesting: (@Sendable (String) throws -> Void)?

    init(
        store: WorkspaceFileContextStore,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        beforeExternalReadOpenForTesting: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.store = store
        self.homeDirectoryURL = homeDirectoryURL
        self.beforeExternalReadOpenForTesting = beforeExternalReadOpenForTesting
    }

    func awaitFreshnessForExplicitRequest(
        _ userPath: String,
        fallbackScope: WorkspaceLookupRootScope
    ) async throws {
        try await awaitFreshnessForExplicitRequest {
            await store.awaitAppliedIngressForExplicitRequest(
                userPath: userPath,
                fallbackScope: fallbackScope
            )
        }
    }

    func awaitFreshnessForExplicitRequest(
        _ userPath: String,
        rootRefs: [WorkspaceRootRef],
        timeout: Duration? = nil
    ) async throws {
        try await awaitFreshnessForExplicitRequest {
            if let timeout {
                try await store.awaitAppliedIngressForExplicitRequest(
                    userPath: userPath,
                    fallbackRootRefs: rootRefs,
                    timeout: timeout
                )
            } else {
                await store.awaitAppliedIngressForExplicitRequest(
                    userPath: userPath,
                    fallbackRootRefs: rootRefs
                )
            }
        }
    }

    private func awaitFreshnessForExplicitRequest(
        samples operation: () async throws -> [WorkspaceIngressBarrierSample]
    ) async throws {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
            correlation: lifecycleCorrelation
        )
        let freshnessState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.explicitIngressFreshnessWait)
        do {
            let samples = try await operation()
            try Task.checkCancellation()
            let dimensions = freshnessDimensions(samples: samples, outcome: "success")
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.explicitIngressFreshnessWait,
                freshnessState,
                dimensions
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: lifecycleCorrelation,
                dimensions
            )
        } catch {
            let dimensions = freshnessDimensions(samples: [], outcome: freshnessOutcome(for: error))
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.explicitIngressFreshnessWait,
                freshnessState,
                dimensions
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
                correlation: lifecycleCorrelation,
                dimensions
            )
            throw error
        }
    }

    private func freshnessDimensions(
        samples: [WorkspaceIngressBarrierSample],
        outcome: String
    ) -> EditFlowPerf.Dimensions {
        EditFlowPerf.Dimensions(
            outcome: outcome,
            rootCount: samples.count,
            pendingRootCount: samples.count(where: { $0.pendingRawEventCountBeforeFlush > 0 }),
            pendingRawEventCount: samples.reduce(0) { $0 + $1.pendingRawEventCountBeforeFlush }
        )
    }

    private func freshnessOutcome(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if (error as? WorkspaceAppliedIngressWaitError) == .timedOut {
            return "timeout"
        }
        return "error"
    }

    static func exactAbsoluteCatalogHitInput(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return expanded
    }

    func resolveExactAbsoluteWorkspaceCatalogHit(
        _ rawPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceFileRecord? {
        guard let absolutePath = Self.exactAbsoluteCatalogHitInput(rawPath) else { return nil }
        return await resolveExactWorkspaceCatalogHit(absolutePath, rootScope: rootScope)
    }

    func resolveExactWorkspaceCatalogHit(
        _ rawPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceFileRecord? {
        guard case let .matched(file) = await store.lookupCatalogFileForExplicitRequest(rawPath, rootScope: rootScope) else {
            return nil
        }
        return file
    }

    func resolveReadableFile(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceReadableFileHandle? {
        let roots = await store.rootRefs(scope: rootScope)
        let namespace = WorkspaceExactFileNamespace.identity(roots: roots)
        let resolution = try await resolveReadFileRequest(
            WorkspaceExactFileInput.parse(userPath),
            rootScope: rootScope,
            rootRefs: roots,
            namespace: namespace
        )
        switch resolution {
        case let .workspace(match):
            return .workspace(match.file)
        case let .external(file):
            return .external(file)
        case .folder, .issue, .noCandidate:
            return nil
        }
    }

    func resolveReadFileRequest(
        _ input: WorkspaceExactFileInput,
        rootScope: WorkspaceLookupRootScope,
        rootRefs roots: [WorkspaceRootRef],
        namespace: WorkspaceExactFileNamespace
    ) async throws -> WorkspaceReadableFileResolution {
        try await FileSystemService.withContentReadForegroundActivity(kind: .readResolution) {
            switch try await store.resolveExactExistingWorkspaceFile(input, namespace: namespace) {
            case let .matched(match):
                return .workspace(match)
            case let .directory(directory):
                return .folder(displayPath: directory.displayPath)
            case let .issue(issue):
                return .issue(issue)
            case .claimedMissing:
                return .noCandidate
            case .noCandidate:
                break
            }

            let path: String
            switch input {
            case let .absolute(absolutePath):
                path = absolutePath
            case let .relative(relativePath):
                path = relativePath
            case .explicitRoot:
                return .noCandidate
            }

            let folderResolution = await store.resolveFolderInput(
                path,
                rootScope: rootScope,
                profile: .mcpRead,
                rootRefs: roots,
                validateIssue: false,
                allowGeneralLookupFallback: false
            )
            if let issue = folderResolution.issue {
                return .issue(issue)
            }
            if let folder = folderResolution.folder {
                let displayPath = folderResolution.displayPath
                    ?? ClientPathFormatter.displayAbsolutePath(
                        fullPath: folder.standardizedFullPath,
                        visibleRoots: roots
                    )
                return .folder(displayPath: displayPath)
            }

            if let externalFolderPath = resolveAlwaysReadableExternalFolderDisplayPath(path) {
                return .folder(displayPath: externalFolderPath)
            }
            guard path.hasPrefix("/") else { return .noCandidate }
            return resolveAlwaysReadableExternalFile(atAbsolutePath: path).map(WorkspaceReadableFileResolution.external)
                ?? .noCandidate
        }
    }

    func resolveAlwaysReadableExternalFolderDisplayPath(_ userPath: String) -> String? {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/"), isAlwaysReadableExternalPath(normalized) else { return nil }
        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: normalized)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return displayPath(forExternalPath: absolutePath)
    }

    func displayPath(forExternalPath userPath: String) -> String {
        AgentSupportDirectoryCatalog.displayPath(for: normalizedInput(userPath), homeDirectoryURL: homeDirectoryURL)
    }

    func isAlwaysReadableExternalPath(_ userPath: String) -> Bool {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/") else { return false }
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL)
        return directories.contains { AgentSupportDirectoryCatalog.contains(absolutePath: normalized, in: $0) }
    }

    func readAlwaysReadableExternalFile(_ file: WorkspaceExternalReadableFile) async throws -> String {
        let path = file.absolutePath
        let homeDirectoryPath = homeDirectoryURL.path
        let byteLimit = Self.externalReadByteLimit
        let chunkSize = Self.externalReadChunkSize
        let workRecorder = MCPToolWorkCountDiagnostics.readFileExternalRecorder()
        let beforeExternalReadOpenHook = beforeExternalReadOpenForTesting
        try Task.checkCancellation()
        let readTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let homeDirectoryURL = URL(fileURLWithPath: homeDirectoryPath)
            let normalizedPath = AgentSupportDirectoryCatalog.normalizedPath(for: path)
            guard normalizedPath.hasPrefix("/") else {
                throw FileSystemError.invalidRelativePath
            }

            let canonicalPath = if FileManager.default.fileExists(atPath: normalizedPath) {
                AgentSupportDirectoryCatalog.normalizedPath(
                    for: URL(fileURLWithPath: normalizedPath).resolvingSymlinksInPath().standardizedFileURL.path
                )
            } else {
                normalizedPath
            }
            let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(
                homeDirectoryURL: homeDirectoryURL
            )
            guard directories.contains(where: {
                AgentSupportDirectoryCatalog.contains(absolutePath: normalizedPath, in: $0)
            }), directories.contains(where: {
                AgentSupportDirectoryCatalog.contains(absolutePath: canonicalPath, in: $0)
            }) else {
                throw FileSystemError.invalidRelativePath
            }
            let canonicalAllowlist = directories.map {
                Self.canonicalizedExternalReadPath($0.standardizedPath)
            }
            if let beforeExternalReadOpenHook {
                try beforeExternalReadOpenHook(canonicalPath)
            }

            let handle = try FileContentFingerprintReader.openReadOnlyFileHandle(atPath: canonicalPath)
            defer { try? handle.close() }
            let openedPath = try Self.openedFilePath(fileDescriptor: handle.fileDescriptor)
            let canonicalOpenedPath = Self.canonicalizedExternalReadPath(openedPath)
            guard canonicalOpenedPath.hasPrefix("/"), canonicalAllowlist.contains(where: {
                Self.isWithinCanonicalDirectory(canonicalOpenedPath, directoryPath: $0)
            }) else {
                throw FileSystemError.invalidRelativePath
            }
            let fingerprint = try FileContentFingerprintReader.fingerprint(fileDescriptor: handle.fileDescriptor)
            try Task.checkCancellation()
            if fingerprint.byteSize > Int64(byteLimit) {
                return "[File too large: \(fingerprint.byteSize) bytes]"
            }

            var data = Data()
            data.reserveCapacity(Int(fingerprint.byteSize))
            while true {
                try Task.checkCancellation()
                let remaining = byteLimit - data.count
                let next = try handle.read(upToCount: min(chunkSize, remaining + 1)) ?? Data()
                try Task.checkCancellation()
                if next.isEmpty { break }
                let observedByteCount = data.count + next.count
                if observedByteCount > byteLimit {
                    return "[File too large: \(observedByteCount) bytes]"
                }
                data.append(next)
            }

            guard try FileContentFingerprintReader.fingerprint(fileDescriptor: handle.fileDescriptor) == fingerprint else {
                throw FileContentValidationError.fingerprintChanged
            }
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            let decoded: String = if let utf8 = String(data: data, encoding: .utf8) {
                utf8
            } else if let unicode = String(data: data, encoding: .unicode) {
                unicode
            } else {
                String(decoding: data, as: UTF8.self)
            }
            let decodeEnd = DispatchTime.now().uptimeNanoseconds
            workRecorder(
                data.count,
                Int(clamping: decodeEnd >= decodeStart ? (decodeEnd - decodeStart) / 1000 : 0)
            )
            return decoded
        }
        return try await withTaskCancellationHandler(operation: {
            try await readTask.value
        }, onCancel: {
            readTask.cancel()
        })
    }

    func resolveAlwaysReadableExternalFile(atAbsolutePath path: String) -> WorkspaceExternalReadableFile? {
        guard isAlwaysReadableExternalPath(path) else { return nil }
        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: path)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return WorkspaceExternalReadableFile(
            absolutePath: absolutePath,
            displayPath: displayPath(forExternalPath: absolutePath)
        )
    }

    private static func canonicalizedExternalReadPath(_ path: String) -> String {
        AgentSupportDirectoryCatalog.normalizedPath(
            for: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    private static func isWithinCanonicalDirectory(_ path: String, directoryPath: String) -> Bool {
        path == directoryPath || path.hasPrefix(directoryPath == "/" ? "/" : directoryPath + "/")
    }

    private static func openedFilePath(fileDescriptor: Int32) throws -> String {
        #if os(macOS)
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { buffer in
                repo_get_file_descriptor_path(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            guard result == 0 else {
                throw FileSystemError.failedToReadFile
            }
            return String(cString: buffer)
        #else
            throw FileSystemError.failedToReadFile
        #endif
    }

    private func normalizedAlwaysReadableAbsolutePath(for path: String) -> String {
        let normalized = AgentSupportDirectoryCatalog.normalizedPath(for: path)
        if FileManager.default.fileExists(atPath: normalized) {
            return AgentSupportDirectoryCatalog.normalizedPath(
                for: URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
        return normalized
    }

    private func normalizedInput(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}
