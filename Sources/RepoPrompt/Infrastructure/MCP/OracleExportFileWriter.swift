import Foundation
import MCP

struct GeneratedOracleExportFileWriter {
    let store: WorkspaceFileContextStore

    @discardableResult
    func write(path rawPath: String, content: String, destination: OracleExportDestination) async throws -> String {
        let resolvedPath = try resolvedAbsoluteExportPath(rawPath, destination: destination)
        let destinationRootPath = StandardizedPath.absolute(destination.primaryRootPath)
        let readableRoots = await store.rootRefs(scope: destination.rootScope)
        guard let readableRoot = readableRoots.first(where: { $0.standardizedFullPath == destinationRootPath }) else {
            let loadedRoots = readableRoots.map(\.standardizedFullPath).joined(separator: ", ")
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(resolvedPath)': workspace primary root '\(destinationRootPath)' is not loaded in the current read_file workspace scope. Loaded readable roots: \(loadedRoots.isEmpty ? "none" : loadedRoots)."
            )
        }
        guard resolvedPath == readableRoot.standardizedFullPath
            || StandardizedPath.isDescendant(resolvedPath, of: readableRoot.standardizedFullPath)
        else {
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(resolvedPath)': target path is outside the current read_file workspace root '\(readableRoot.standardizedFullPath)'."
            )
        }

        let fm = FileManager.default
        guard !fm.fileExists(atPath: resolvedPath) else {
            throw MCPError.invalidParams("Cannot create generated Oracle export at '\(resolvedPath)': path already exists.")
        }

        let mutationService = WorkspaceFileMutationService(store: store)
        do {
            let writeResult = try await mutationService.createFileWithPostcondition(
                userPath: resolvedPath,
                content: content,
                rootScope: destination.rootScope,
                pathResolutionPolicy: .literalPreferredIfStronger
            )

            if let reason = writeResult.catalogIneligibility {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(resolvedPath)', but that path is not readable by read_file because \(reason.description). Remove the workspace policy/ignore exclusion for this export path and try again."
                )
            }
            guard writeResult.materializedFile != nil else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(resolvedPath)', but RepoPrompt did not add it to the workspace catalog, so read_file cannot read it."
                )
            }

            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: resolvedPath,
                fallbackScope: destination.rootScope
            )
            try await assertReadFileCanReadExport(
                path: resolvedPath,
                expectedContent: content,
                rootScope: destination.rootScope
            )
            return resolvedPath
        } catch let error as MCPError {
            await cleanupCreatedExportIfPresent(
                path: resolvedPath,
                root: readableRoot,
                rootScope: destination.rootScope
            )
            throw error
        } catch let error as FileManagerError {
            await cleanupCreatedExportIfPresent(
                path: resolvedPath,
                root: readableRoot,
                rootScope: destination.rootScope
            )
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(resolvedPath)': \(error.localizedDescription)"
            )
        } catch {
            await cleanupCreatedExportIfPresent(
                path: resolvedPath,
                root: readableRoot,
                rootScope: destination.rootScope
            )
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(resolvedPath)': \(error.localizedDescription)"
            )
        }
    }

    private func resolvedAbsoluteExportPath(_ rawPath: String, destination: OracleExportDestination) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: export path is empty.")
        }
        let expandedPath = (trimmed as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: generated export path must resolve to an absolute workspace path, got '\(trimmed)'.")
        }
        let resolvedPath = StandardizedPath.absolute(expandedPath)
        let rootPath = StandardizedPath.absolute(destination.primaryRootPath)
        guard resolvedPath == rootPath || StandardizedPath.isDescendant(resolvedPath, of: rootPath) else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: generated path escapes the workspace primary root.")
        }
        return resolvedPath
    }

    private func cleanupCreatedExportIfPresent(
        path resolvedPath: String,
        root: WorkspaceRootRef,
        rootScope: WorkspaceLookupRootScope
    ) async {
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return }
        try? FileManager.default.removeItem(atPath: resolvedPath)
        let rootPrefix = root.standardizedFullPath.hasSuffix("/") ? root.standardizedFullPath : root.standardizedFullPath + "/"
        guard resolvedPath.hasPrefix(rootPrefix) else { return }
        let relativePath = StandardizedPath.relative(String(resolvedPath.dropFirst(rootPrefix.count)))
        await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileRemoved(relativePath)])
        _ = await store.awaitAppliedIngressForExplicitRequest(
            userPath: resolvedPath,
            fallbackScope: rootScope
        )
    }

    private func assertReadFileCanReadExport(
        path resolvedPath: String,
        expectedContent: String,
        rootScope: WorkspaceLookupRootScope
    ) async throws {
        let readableService = WorkspaceReadableFileService(store: store)
        let readable = await readableService.resolveReadableFile(
            resolvedPath,
            profile: .mcpRead,
            rootScope: rootScope
        )
        guard case let .workspace(file) = readable else {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(resolvedPath)', but read_file cannot resolve that exact path in the current workspace."
            )
        }
        guard file.standardizedFullPath == resolvedPath else {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(resolvedPath)', but read_file resolved a different workspace file ('\(file.standardizedFullPath)')."
            )
        }
        do {
            guard let loadedContent = try await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath) else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(resolvedPath)', but read_file cannot load its contents."
                )
            }
            guard loadedContent == expectedContent else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(resolvedPath)', but read_file loaded different contents."
                )
            }
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(resolvedPath)', but read_file cannot load its contents: \(error.localizedDescription)"
            )
        }
    }
}
