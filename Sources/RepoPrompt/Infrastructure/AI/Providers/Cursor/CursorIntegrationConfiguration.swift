import CryptoKit
import Darwin
import Foundation

/// Cursor-specific MCP integration helpers.
///
/// Cursor Agent accepts modern ACP `session/new` MCP injection, but applies the same
/// project-scoped approval gate used for configured MCP servers before starting an injected
/// server. RepoPrompt therefore leases the matching approval identifier for the run while
/// continuing to use ACP injection as the only server configuration mechanism.
enum CursorIntegrationConfiguration {
    static let cleanupArtifactKind = "cursorProjectMCPApproval"
    private static let approvalFileName = "mcp-approvals.json"
    private static let fileLock = NSLock()
    private static let leaseStore = CursorProjectMCPApprovalLeaseStore()

    struct ProjectMCPApprovalLease: Equatable {
        let id: UUID
        let approvalURL: URL
        let directoryURL: URL
        let previousData: Data?
        let writtenData: Data
        let createdDirectory: Bool
        let insertedApprovalIDs: Set<String>
    }

    static func cursorDataDirectoryURL(
        workingDirectory: String,
        environment: [String: String]
    ) -> URL {
        let workingDirectoryURL = standardizedWorkingDirectoryURL(workingDirectory)
        let configuredDataDirectory = environment["CURSOR_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPath: String
        if let configuredDataDirectory, !configuredDataDirectory.isEmpty {
            rawPath = configuredDataDirectory
        } else {
            let configuredHome = environment["HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let homePath: String = if let configuredHome, !configuredHome.isEmpty {
                configuredHome
            } else {
                FileManager.default.homeDirectoryForCurrentUser.path
            }
            rawPath = URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent(".cursor", isDirectory: true)
                .path
        }

        let expandedPath = expandedPath(rawPath, environment: environment)
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        }
        return URL(
            fileURLWithPath: expandedPath,
            isDirectory: true,
            relativeTo: workingDirectoryURL
        ).standardizedFileURL
    }

    static func projectRootURL(workingDirectory: String) -> URL {
        let workingDirectoryURL = standardizedWorkingDirectoryURL(workingDirectory)
        var candidate = workingDirectoryURL
        while true {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(".git").path
            ) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return workingDirectoryURL
    }

    static func projectMCPApprovalURL(
        workingDirectory: String,
        cursorDataDirectory: URL
    ) -> URL {
        cursorProjectDirectoryURL(
            projectRoot: projectRootURL(workingDirectory: workingDirectory),
            cursorDataDirectory: cursorDataDirectory
        )
        .appendingPathComponent(approvalFileName)
    }

    static func approvalIdentifier(
        projectRoot: String,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    ) throws -> String {
        let payload = try cursorApprovalPayload(
            projectRoot: projectRoot,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration
        )
        let digest = SHA256.hash(data: Data(payload.utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(repoPromptMCPConfiguration.name)-\(prefix)"
    }

    @discardableResult
    static func prepareProjectMCPApproval(
        workingDirectory: String,
        cursorDataDirectory: URL,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        cleanupAfterRun: Bool = true
    ) throws -> ACPLaunchCleanupArtifact? {
        fileLock.lock()
        defer { fileLock.unlock() }

        let fm = FileManager.default
        let projectRoot = projectRootURL(workingDirectory: workingDirectory)
        let directoryURL = cursorProjectDirectoryURL(
            projectRoot: projectRoot,
            cursorDataDirectory: cursorDataDirectory
        )
        let approvalURL = directoryURL.appendingPathComponent(approvalFileName)

        var isDirectory: ObjCBool = false
        let directoryExists = fm.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        if directoryExists, !isDirectory.boolValue {
            throw AIProviderError.invalidConfiguration(
                detail: "Unable to prepare Cursor MCP approval: \(directoryURL.path) exists but is not a directory."
            )
        }
        let createdDirectory = !directoryExists
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let previousData: Data?
        if fm.fileExists(atPath: approvalURL.path) {
            do {
                previousData = try Data(contentsOf: approvalURL)
            } catch {
                throw AIProviderError.invalidConfiguration(
                    detail: "Unable to read Cursor MCP approvals at \(approvalURL.path): \(error.localizedDescription)"
                )
            }
        } else {
            previousData = nil
        }

        var approvals = try existingApprovals(from: previousData, approvalURL: approvalURL)
        let approval = try approvalIdentifier(
            projectRoot: projectRoot.path,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration
        )
        let insertedApprovalIDs: Set<String>
        let writtenData: Data
        if approvals.contains(approval), let previousData {
            insertedApprovalIDs = []
            writtenData = previousData
        } else {
            insertedApprovalIDs = [approval]
            approvals.append(approval)
            writtenData = try JSONSerialization.data(
                withJSONObject: approvals,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
            try writtenData.write(to: approvalURL, options: .atomic)
        }

        guard cleanupAfterRun else { return nil }
        let lease = ProjectMCPApprovalLease(
            id: UUID(),
            approvalURL: approvalURL,
            directoryURL: directoryURL,
            previousData: previousData,
            writtenData: writtenData,
            createdDirectory: createdDirectory,
            insertedApprovalIDs: insertedApprovalIDs
        )
        leaseStore.register(lease)
        return ACPLaunchCleanupArtifact(
            providerID: .cursor,
            id: lease.id,
            kind: cleanupArtifactKind
        )
    }

    static func cleanupProjectMCPApproval(leaseID: UUID) {
        fileLock.lock()
        defer { fileLock.unlock() }

        let fm = FileManager.default
        switch leaseStore.cleanupDisposition(for: leaseID) {
        case .none, .deferred:
            return
        case let .final(state):
            do {
                try cleanupInsertedApprovals(state: state, fileManager: fm)
                leaseStore.completeFinalCleanup(leaseID: leaseID)
            } catch {
                // Keep the final lease registered so cleanup can be retried after a transient
                // read/parse/write failure instead of permanently orphaning our approval IDs.
                #if DEBUG
                    print("[CursorIntegrationConfiguration] Cleanup failed for \(state.approvalURL.path): \(error.localizedDescription)")
                #endif
            }
        }
    }

    private static func cleanupInsertedApprovals(
        state: CursorProjectMCPApprovalLeaseStore.PathLeaseState,
        fileManager: FileManager
    ) throws {
        guard !state.insertedApprovalIDs.isEmpty else { return }
        guard fileManager.fileExists(atPath: state.approvalURL.path) else {
            removeDirectoryIfOwnedAndEmpty(state: state, fileManager: fileManager)
            return
        }

        let currentData = try Data(contentsOf: state.approvalURL)
        let currentApprovals = try existingApprovals(
            from: currentData,
            approvalURL: state.approvalURL
        )
        let retainedApprovals = currentApprovals.filter {
            !state.insertedApprovalIDs.contains($0)
        }
        guard retainedApprovals.count != currentApprovals.count else { return }

        if retainedApprovals.isEmpty, state.originalPreviousData == nil {
            try fileManager.removeItem(at: state.approvalURL)
            removeDirectoryIfOwnedAndEmpty(state: state, fileManager: fileManager)
            return
        }
        let retainedData = try JSONSerialization.data(
            withJSONObject: retainedApprovals,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        try retainedData.write(to: state.approvalURL, options: .atomic)
    }

    private static func removeDirectoryIfOwnedAndEmpty(
        state: CursorProjectMCPApprovalLeaseStore.PathLeaseState,
        fileManager: FileManager
    ) {
        if state.originalCreatedDirectory,
           let contents = try? fileManager.contentsOfDirectory(atPath: state.directoryURL.path),
           contents.isEmpty
        {
            try? fileManager.removeItem(at: state.directoryURL)
        }
    }

    private static func cursorProjectDirectoryURL(
        projectRoot: URL,
        cursorDataDirectory: URL
    ) -> URL {
        cursorDataDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(cursorProjectPathComponent(projectRoot.path), isDirectory: true)
    }

    private static func cursorProjectPathComponent(_ path: String) -> String {
        path
            .replacingOccurrences(
                of: #"[^a-zA-Z0-9]"#,
                with: "-",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"-+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func cursorApprovalPayload(
        projectRoot: String,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    ) throws -> String {
        let pathJSON = try JSONSerialization.stringFragment(projectRoot)
        let commandJSON = try JSONSerialization.stringFragment(repoPromptMCPConfiguration.command)
        let argsData = try JSONSerialization.data(
            withJSONObject: repoPromptMCPConfiguration.args,
            options: [.withoutEscapingSlashes]
        )
        guard let argsJSON = String(data: argsData, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        var orderedEnvironmentNames: [String] = []
        var environmentValues: [String: String] = [:]
        for entry in repoPromptMCPConfiguration.env {
            if environmentValues[entry.name] == nil {
                orderedEnvironmentNames.append(entry.name)
            }
            environmentValues[entry.name] = entry.value
        }
        let environmentJSON = try cursorJSONObjectKeyOrder(orderedEnvironmentNames).map { name in
            let value = environmentValues[name] ?? ""
            return try "\(JSONSerialization.stringFragment(name)):\(JSONSerialization.stringFragment(value))"
        }.joined(separator: ",")

        return #"{"path":\#(pathJSON),"server":{"command":\#(commandJSON),"args":\#(argsJSON),"env":{\#(environmentJSON)}}}"#
    }

    private static func cursorJSONObjectKeyOrder(_ keys: [String]) -> [String] {
        let indexed = keys.compactMap { key -> (key: String, index: UInt32)? in
            guard let index = UInt32(key),
                  index != UInt32.max,
                  String(index) == key
            else {
                return nil
            }
            return (key, index)
        }
        let indexedKeys = Set(indexed.map(\.key))
        return indexed.sorted { $0.index < $1.index }.map(\.key)
            + keys.filter { !indexedKeys.contains($0) }
    }

    private static func existingApprovals(
        from data: Data?,
        approvalURL: URL
    ) throws -> [String] {
        guard let data else { return [] }
        do {
            guard let approvals = try JSONSerialization.jsonObject(with: data) as? [String] else {
                throw AIProviderError.invalidConfiguration(
                    detail: "Unable to merge Cursor MCP approvals at \(approvalURL.path): expected a JSON string array."
                )
            }
            return approvals
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidConfiguration(
                detail: "Unable to merge Cursor MCP approvals at \(approvalURL.path): invalid JSON."
            )
        }
    }

    private static func expandedPath(
        _ path: String,
        environment: [String: String]
    ) -> String {
        var expanded = path
        if expanded == "~" || expanded.hasPrefix("~/") {
            let home = environment["HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let homePath: String = if let home, !home.isEmpty {
                home
            } else {
                FileManager.default.homeDirectoryForCurrentUser.path
            }
            expanded = homePath + expanded.dropFirst()
        }
        return CommandPathResolver.expandPath(expanded, environment: environment)
    }

    private static func standardizedWorkingDirectoryURL(_ workingDirectory: String) -> URL {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? FileManager.default.temporaryDirectory.path : trimmed
        let standardizedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let physicalPath = standardizedURL.path.withCString { cPath -> String? in
            guard let resolved = realpath(cPath, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return physicalPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? standardizedURL
    }
}

private extension JSONSerialization {
    static func stringFragment(_ value: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return string
    }
}

private final class CursorProjectMCPApprovalLeaseStore: @unchecked Sendable {
    struct PathLeaseState {
        let approvalURL: URL
        let directoryURL: URL
        let originalPreviousData: Data?
        let originalCreatedDirectory: Bool
        var activeLeaseIDs: Set<UUID>
        var insertedApprovalIDs: Set<String>
    }

    enum CleanupDisposition {
        case deferred
        case final(PathLeaseState)
    }

    private let lock = NSLock()
    private var approvalPathByLeaseID: [UUID: String] = [:]
    private var stateByApprovalPath: [String: PathLeaseState] = [:]

    func register(_ lease: CursorIntegrationConfiguration.ProjectMCPApprovalLease) {
        lock.lock()
        defer { lock.unlock() }

        let key = lease.approvalURL.standardizedFileURL.path
        approvalPathByLeaseID[lease.id] = key
        if var state = stateByApprovalPath[key] {
            state.activeLeaseIDs.insert(lease.id)
            state.insertedApprovalIDs.formUnion(lease.insertedApprovalIDs)
            stateByApprovalPath[key] = state
        } else {
            stateByApprovalPath[key] = PathLeaseState(
                approvalURL: lease.approvalURL,
                directoryURL: lease.directoryURL,
                originalPreviousData: lease.previousData,
                originalCreatedDirectory: lease.createdDirectory,
                activeLeaseIDs: [lease.id],
                insertedApprovalIDs: lease.insertedApprovalIDs
            )
        }
    }

    func cleanupDisposition(for leaseID: UUID) -> CleanupDisposition? {
        lock.lock()
        defer { lock.unlock() }

        guard let key = approvalPathByLeaseID[leaseID],
              var state = stateByApprovalPath[key]
        else {
            return nil
        }
        if state.activeLeaseIDs.count > 1 {
            state.activeLeaseIDs.remove(leaseID)
            stateByApprovalPath[key] = state
            approvalPathByLeaseID.removeValue(forKey: leaseID)
            return .deferred
        }
        return .final(state)
    }

    func completeFinalCleanup(leaseID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard let key = approvalPathByLeaseID.removeValue(forKey: leaseID) else { return }
        stateByApprovalPath.removeValue(forKey: key)
    }
}
