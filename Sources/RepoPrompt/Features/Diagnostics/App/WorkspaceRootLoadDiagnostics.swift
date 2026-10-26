import Foundation
import RepoPromptWorkspaceCore

#if DEBUG
    /// Debug-only root-load trace correlation for workspace restore metrics.
    ///
    /// This helper bridges `WorkspaceManagerViewModel` workspace-switch trace context to
    /// `WorkspaceFileContextStore` root-load events without making measurement-only
    /// fields part of the core workspace store API. Context is scoped to an async
    /// operation and keyed by the same standardized root path used by the store.
    enum WorkspaceRootLoadDiagnostics {
        struct Context {
            let workspaceSwitchID: UUID?
            let workspaceID: UUID?
            let generation: UInt64?
            let rootIndex: Int?
            let rootName: String
            let switchStartMS: Double?
            let loadWorkspaceFoldersStartMS: Double?
        }

        private struct Entry {
            let token: UUID
            let context: Context
        }

        private static let lock = NSLock()
        private static var contextsByStandardizedPath: [String: [Entry]] = [:]

        static func withContext<T>(
            _ context: Context?,
            path: String,
            operation: () async throws -> T
        ) async rethrows -> T {
            guard let context, WorkspaceRestorePerfLog.isEnabled else {
                return try await operation()
            }

            let standardizedPath = standardize(path)
            let token = UUID()
            register(context, path: standardizedPath, token: token)
            defer { unregister(path: standardizedPath, token: token) }
            return try await operation()
        }

        static func rootRecordCreatedFields(forPath path: String) -> [String: String] {
            guard let context = latestContext(forPath: path) else { return [:] }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            return [
                "workspaceSwitchID": context.workspaceSwitchID?.uuidString ?? "nil",
                "workspaceID": WorkspaceRestorePerfLog.shortID(context.workspaceID),
                "generation": context.generation.map(String.init) ?? "nil",
                "rootIndex": context.rootIndex.map(String.init) ?? "nil",
                "traceRootName": context.rootName,
                "durationSinceSwitchBegin": context.switchStartMS.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notMeasured",
                "durationSinceLoadWorkspaceFoldersBegin": context.loadWorkspaceFoldersStartMS.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notMeasured"
            ]
        }

        static func firstPreparedChunkFields(forPath path: String) -> [String: String] {
            guard let context = latestContext(forPath: path) else { return [:] }
            let nowMS = WorkspaceRestorePerfLog.timestampMS()
            return [
                "workspaceSwitchID": context.workspaceSwitchID?.uuidString ?? "nil",
                "workspaceID": WorkspaceRestorePerfLog.shortID(context.workspaceID),
                "generation": context.generation.map(String.init) ?? "nil",
                "rootIndex": context.rootIndex.map(String.init) ?? "nil",
                "durationSinceSwitchBegin": context.switchStartMS.map { WorkspaceRestorePerfLog.formatMS(nowMS - $0) } ?? "notMeasured"
            ]
        }

        private static func standardize(_ path: String) -> String {
            (path as NSString).standardizingPath
        }

        private static func register(_ context: Context, path: String, token: UUID) {
            lock.lock()
            contextsByStandardizedPath[path, default: []].append(Entry(token: token, context: context))
            lock.unlock()
        }

        private static func unregister(path: String, token: UUID) {
            lock.lock()
            if var entries = contextsByStandardizedPath[path] {
                entries.removeAll { $0.token == token }
                if entries.isEmpty {
                    contextsByStandardizedPath.removeValue(forKey: path)
                } else {
                    contextsByStandardizedPath[path] = entries
                }
            }
            lock.unlock()
        }

        private static func latestContext(forPath path: String) -> Context? {
            let standardizedPath = standardize(path)
            lock.lock()
            let context = contextsByStandardizedPath[standardizedPath]?.last?.context
            lock.unlock()
            return context
        }
    }

    struct AppWorkspaceRootLoadFieldProvider: WorkspaceRootLoadFieldProviding {
        func rootRecordCreatedFields(forPath path: String) -> [String: String] {
            WorkspaceRootLoadDiagnostics.rootRecordCreatedFields(forPath: path)
        }

        func firstPreparedChunkFields(forPath path: String) -> [String: String] {
            WorkspaceRootLoadDiagnostics.firstPreparedChunkFields(forPath: path)
        }
    }
#endif
