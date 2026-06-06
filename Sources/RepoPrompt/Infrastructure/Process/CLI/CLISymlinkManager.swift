import Darwin
import Foundation
import OSLog
import RepoPromptShared

/// Maintains the flavor-specific CE user-space link. The link is repaired only
/// when its existing destination is on the explicit CE managed allowlist.
enum CLISymlinkManagerUserSpace {
    private static let logger = Logger(
        subsystem: "CLI.SymlinkMgr",
        category: "install"
    )

    #if DEBUG
        static let identity = MCPFilesystemIdentity.repoPromptCE(.debug)
    #else
        static let identity = MCPFilesystemIdentity.repoPromptCE(.release)
    #endif

    static var userSymlinkPath: String {
        identity.userSpaceCLIURL().path
    }

    static var stableCLIPath: String {
        guard let cliURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp") else {
            logger.error("Bundled CLI not found")
            return userSymlinkPath
        }
        _ = ensureLocalSymlink(userSymlinkURL: URL(fileURLWithPath: userSymlinkPath), bundledCLIURL: cliURL)
        if validateSymlink(userSymlinkURL: URL(fileURLWithPath: userSymlinkPath), bundledCLIURL: cliURL) {
            return userSymlinkPath
        }
        logger.info("Managed symlink unavailable, falling back to bundle path: \(cliURL.path)")
        return cliURL.path
    }

    static func validateSymlink() -> Bool {
        guard let cliURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp") else { return false }
        return validateSymlink(userSymlinkURL: URL(fileURLWithPath: userSymlinkPath), bundledCLIURL: cliURL)
    }

    static func ensureLocalSymlink() {
        guard let cliURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp") else {
            logger.error("Bundled CLI not found")
            return
        }
        _ = ensureLocalSymlink(userSymlinkURL: URL(fileURLWithPath: userSymlinkPath), bundledCLIURL: cliURL)
    }

    @discardableResult
    static func ensureLocalSymlink(
        userSymlinkURL: URL,
        bundledCLIURL: URL,
        fileManager: FileManager = .default,
        beforeCommit: (() -> Void)? = nil
    ) -> Bool {
        let supportDirectory = userSymlinkURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            logger.error("Failed to create CLI support directory: \(error.localizedDescription)")
            return false
        }

        let allowlist = ManagedCLIPathPolicy.managedDestinations(
            currentBundledCLIPath: bundledCLIURL.path,
            fileManager: fileManager
        )
        let initial = ManagedCLIPathPolicy.classifySymlink(
            at: userSymlinkURL.path,
            desiredDestination: bundledCLIURL.path,
            managedDestinations: allowlist,
            fileManager: fileManager
        )
        switch initial {
        case .managedCurrent:
            return true
        case .unmanaged:
            logger.error("Refusing to replace unmanaged CLI entry at \(userSymlinkURL.path)")
            return false
        case .missing, .managedStale:
            break
        }

        let temporaryURL = supportDirectory.appendingPathComponent(".\(userSymlinkURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.createSymbolicLink(
                atPath: temporaryURL.path,
                withDestinationPath: bundledCLIURL.path
            )
            guard commitManagedSymlink(
                temporaryURL: temporaryURL,
                destinationURL: userSymlinkURL,
                desiredDestination: bundledCLIURL.path,
                managedDestinations: allowlist,
                fileManager: fileManager,
                beforeCommit: beforeCommit
            ) else {
                return false
            }
            return validateSymlink(
                userSymlinkURL: userSymlinkURL,
                bundledCLIURL: bundledCLIURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            logger.error("Failed to install managed user-space symlink: \(error.localizedDescription)")
            return false
        }
    }

    private static func commitManagedSymlink(
        temporaryURL: URL,
        destinationURL: URL,
        desiredDestination: String,
        managedDestinations: Set<String>,
        fileManager: FileManager,
        beforeCommit: (() -> Void)?
    ) -> Bool {
        var beforeCommit = beforeCommit
        for _ in 0 ..< 3 {
            let classification = ManagedCLIPathPolicy.classifySymlink(
                at: destinationURL.path,
                desiredDestination: desiredDestination,
                managedDestinations: managedDestinations,
                fileManager: fileManager
            )
            guard classification != .unmanaged else {
                try? fileManager.removeItem(at: temporaryURL)
                logger.error("Refusing to replace unmanaged CLI entry at \(destinationURL.path)")
                return false
            }

            beforeCommit?()
            beforeCommit = nil

            switch classification {
            case .missing:
                if renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 {
                    return true
                }
                if errno == EEXIST || errno == ENOENT { continue }
            case .managedCurrent, .managedStale:
                if renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_SWAP)) != 0 {
                    if errno == ENOENT { continue }
                    break
                }
                let displaced = ManagedCLIPathPolicy.classifySymlink(
                    at: temporaryURL.path,
                    desiredDestination: desiredDestination,
                    managedDestinations: managedDestinations,
                    fileManager: fileManager
                )
                guard displaced != .unmanaged else {
                    if renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_SWAP)) == 0 {
                        try? fileManager.removeItem(at: temporaryURL)
                    } else {
                        logger.fault("Could not roll back raced unmanaged CLI entry; preserved it at \(temporaryURL.path)")
                    }
                    logger.error("CLI entry ownership changed during replacement at \(destinationURL.path)")
                    return false
                }
                try? fileManager.removeItem(at: temporaryURL)
                return true
            case .unmanaged:
                break
            }
        }

        try? fileManager.removeItem(at: temporaryURL)
        logger.error("Failed to atomically install managed user-space symlink at \(destinationURL.path)")
        return false
    }

    static func validateSymlink(
        userSymlinkURL: URL,
        bundledCLIURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let classification = ManagedCLIPathPolicy.classifySymlink(
            at: userSymlinkURL.path,
            desiredDestination: bundledCLIURL.path,
            managedDestinations: ManagedCLIPathPolicy.managedDestinations(
                currentBundledCLIPath: bundledCLIURL.path,
                fileManager: fileManager
            ),
            fileManager: fileManager
        )
        guard case .managedCurrent = classification else { return false }
        return fileManager.isExecutableFile(atPath: bundledCLIURL.path)
    }
}
