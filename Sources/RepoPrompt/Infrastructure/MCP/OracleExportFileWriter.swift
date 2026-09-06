import Foundation
import MCP

struct GeneratedOracleExportFileWriter {
    let store: WorkspaceFileContextStore

    @discardableResult
    func write(path rawPath: String, content: String, destination: OracleExportDestination) async throws -> String {
        let logicalPath = try resolvedAbsoluteExportPath(rawPath, destination: destination)
        let physicalPath = StandardizedPath.absolute(destination.lookupContext.translateInputPath(logicalPath))
        let physicalRootPath = StandardizedPath.absolute(
            destination.lookupContext.translateInputPath(destination.primaryRootPath)
        )
        let scopedRoots = await store.rootRefs(scope: destination.lookupContext.rootScope)
        guard let scopedRoot = scopedRoots.first(where: { $0.standardizedFullPath == physicalRootPath }) else {
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': destination root is not loaded in the bound read_file workspace scope."
            )
        }
        guard physicalPath == scopedRoot.standardizedFullPath
            || StandardizedPath.isDescendant(physicalPath, of: scopedRoot.standardizedFullPath)
        else {
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': translated target path is outside the bound workspace root."
            )
        }

        let fm = FileManager.default
        guard !fm.fileExists(atPath: physicalPath) else {
            throw MCPError.invalidParams("Cannot create generated Oracle export at '\(logicalPath)': path already exists.")
        }

        let mutationService = WorkspaceFileMutationService(store: store)
        do {
            let writeResult = try await mutationService.createFileWithPostcondition(
                userPath: physicalPath,
                content: content,
                overwrite: false,
                rootScope: destination.lookupContext.rootScope,
                pathResolutionPolicy: .literalPreferredIfStronger
            )
            if let reason = writeResult.catalogIneligibility {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but that path is not readable by read_file because \(reason.description). Remove the workspace policy/ignore exclusion for this export path and try again."
                )
            }
            guard writeResult.materializedFile != nil else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but RepoPrompt did not add it to the workspace catalog, so read_file cannot read it."
                )
            }

            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: physicalPath,
                fallbackScope: destination.lookupContext.rootScope
            )
            try await assertReadFileCanReadExport(
                physicalPath: physicalPath,
                logicalPath: logicalPath,
                expectedContent: content,
                rootScope: destination.lookupContext.rootScope
            )
            return logicalPath
        } catch FileSystemError.fileAlreadyExists {
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': path already exists."
            )
        } catch is FileManagerError {
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': filesystem operation failed."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw partialCreationError(logicalPath: logicalPath, underlying: error)
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

    private func partialCreationError(logicalPath: String, underlying: Error) -> MCPError {
        MCPError.invalidParams(
            "Cannot create generated Oracle export at '\(logicalPath)': \(String(describing: underlying)). Output may remain at the requested path; inspect it before retrying and do not blindly retry."
        )
    }

    private func assertReadFileCanReadExport(
        physicalPath: String,
        logicalPath: String,
        expectedContent: String,
        rootScope: WorkspaceLookupRootScope
    ) async throws {
        let readableService = WorkspaceReadableFileService(store: store)
        let readable = try await readableService.resolveReadableFile(
            physicalPath,
            rootScope: rootScope
        )
        guard case let .workspace(file) = readable else {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(logicalPath)', but read_file cannot resolve that exact path in the bound workspace."
            )
        }
        guard file.standardizedFullPath == physicalPath else {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(logicalPath)', but read_file resolved a different workspace file."
            )
        }
        do {
            guard let loadedContent = try await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath) else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but read_file cannot load its contents."
                )
            }
            guard loadedContent == expectedContent else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but read_file loaded different contents."
                )
            }
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(logicalPath)', but read_file cannot load its contents."
            )
        }
    }
}
