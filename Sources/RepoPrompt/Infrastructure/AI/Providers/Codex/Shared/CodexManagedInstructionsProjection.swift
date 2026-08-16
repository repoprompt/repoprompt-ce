import CryptoKit
import Darwin
import Foundation

/// Projects Codex's effective ordinary user-global instructions into RepoPrompt's isolated home.
/// The projection is one-way and only replaces or removes regular files whose ownership is
/// proven by the sidecar. A pending receipt makes interrupted updates recoverable without
/// deleting the last known-good owned projection before every conflict has been validated.
enum CodexManagedInstructionsProjection {
    static let overrideName = "AGENTS.override.md"
    static let fallbackName = "AGENTS.md"
    static let sidecarName = ".repoprompt-global-instructions.json"
    private static let owner = "com.repoprompt.ce.codex-global-instructions"
    private static let lock = NSLock()

    enum ProjectionError: LocalizedError, Equatable {
        case invalidSource(String)
        case foreignTarget(String)
        case invalidSidecar(String)
        case modifiedProjection(String)

        var errorDescription: String? {
            switch self {
            case let .invalidSource(message), let .foreignTarget(message),
                 let .invalidSidecar(message), let .modifiedProjection(message):
                message
            }
        }

        var privacyBoundedDiagnostic: String {
            switch self {
            case .invalidSource:
                "Projection is blocked because an instruction path is missing, unreadable, non-regular, or uses a symbolic link. RepoPrompt preserved all files."
            case .foreignTarget:
                "Projection is blocked by a managed-home instruction file that RepoPrompt does not own. Move or rename that file, then reconnect Codex."
            case .invalidSidecar:
                "Projection ownership metadata is foreign, modified, malformed, or uses a symbolic link. RepoPrompt preserved it; remove it only after reviewing the managed home."
            case .modifiedProjection:
                "A RepoPrompt-owned instruction projection was modified outside RepoPrompt. It was preserved; review the managed home before reconnecting Codex."
            }
        }
    }

    enum State: Equatable {
        case projected(source: URL, target: URL)
        case absent(managedHome: URL)
        case conflict(message: String)
    }

    struct Diagnostic: Equatable {
        enum Status: Equatable {
            case current(sourceName: String)
            case absent
            case conflict
            case error
        }

        let status: Status
        let message: String
    }

    enum MutationCheckpoint: Equatable {
        case afterPendingReceipt
        case afterTargetWrite
        case afterPreviousTargetRemoval
        case afterOwnedTargetRemoval
    }

    private struct Receipt: Codable, Equatable {
        enum Phase: String, Codable { case pending, committed }
        enum Operation: String, Codable { case project, remove }

        let schemaVersion: Int
        let owner: String
        let sourceName: String
        let targetName: String
        let previousTargetName: String?
        let previousTargetHash: String?
        let projectedHash: String
        let phase: Phase
        let operation: Operation?

        var effectiveOperation: Operation {
            operation ?? .project
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int
        let modificationNanoseconds: Int

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = status.st_size
            modificationSeconds = status.st_mtimespec.tv_sec
            modificationNanoseconds = status.st_mtimespec.tv_nsec
        }
    }

    static func projectBeforeLaunch(
        managedHome: URL,
        ordinaryHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default,
        checkpoint: ((MutationCheckpoint) throws -> Void)? = nil
    ) throws -> State {
        lock.lock()
        defer { lock.unlock() }

        try prepareManagedHome(managedHome, fileManager: fileManager)
        try requireDirectoryChainWithoutSymbolicLink(
            ordinaryHome,
            label: "ordinary Codex home",
            allowMissing: true,
            ancestorDepth: 1
        )

        let sidecar = managedHome.appendingPathComponent(sidecarName, isDirectory: false)
        var receipt = try loadReceipt(at: sidecar)
        if let pending = receipt, pending.phase == .pending {
            receipt = try recoverInterruptedProjection(
                pending,
                managedHome: managedHome,
                sidecar: sidecar,
                fileManager: fileManager
            )
        }

        let selection = try effectiveSource(in: ordinaryHome)
        let hashes = try targetHashes(in: managedHome)
        if let receipt {
            try validateCommittedReceipt(receipt, hashes: hashes)
        } else if !hashes.isEmpty {
            throw ProjectionError.foreignTarget(
                "Preserving managed-home instruction files without a RepoPrompt ownership receipt."
            )
        }

        guard let selection else {
            if let receipt {
                let pendingRemoval = Receipt(
                    schemaVersion: 2,
                    owner: owner,
                    sourceName: receipt.sourceName,
                    targetName: receipt.targetName,
                    previousTargetName: receipt.targetName,
                    previousTargetHash: receipt.projectedHash,
                    projectedHash: receipt.projectedHash,
                    phase: .pending,
                    operation: .remove
                )
                try writeReceipt(pendingRemoval, to: sidecar)
                let target = managedHome.appendingPathComponent(receipt.targetName)
                try removeRegularFile(target, expectedHash: receipt.projectedHash, fileManager: fileManager)
                try checkpoint?(.afterOwnedTargetRemoval)
                try removeRegularSidecarIfPresent(sidecar, fileManager: fileManager)
            }
            return .absent(managedHome: managedHome)
        }

        let sourceData = try readStableRegularFile(selection.url, label: "ordinary \(selection.name)")
        let sourceHash = digest(sourceData)
        let target = managedHome.appendingPathComponent(selection.name, isDirectory: false)

        if let receipt,
           receipt.targetName == selection.name,
           receipt.projectedHash == sourceHash
        {
            return .projected(source: selection.url, target: target)
        }

        let previousTargetName = receipt?.targetName
        let previousTargetHash = receipt?.projectedHash
        if previousTargetName != selection.name, hashes[selection.name] != nil {
            throw ProjectionError.foreignTarget(
                "Preserving a managed-home instruction target that is not owned by the current receipt."
            )
        }

        let pending = Receipt(
            schemaVersion: 2,
            owner: owner,
            sourceName: selection.name,
            targetName: selection.name,
            previousTargetName: previousTargetName,
            previousTargetHash: previousTargetHash,
            projectedHash: sourceHash,
            phase: .pending,
            operation: .project
        )
        try writeReceipt(pending, to: sidecar)
        try checkpoint?(.afterPendingReceipt)

        try sourceData.write(to: target, options: .atomic)
        try requireRegularFile(target, label: "managed instruction projection")
        guard try hashOfRegularFile(target) == sourceHash else {
            throw ProjectionError.modifiedProjection(
                "Managed instruction projection changed while it was being written."
            )
        }
        try checkpoint?(.afterTargetWrite)

        if let previousTargetName,
           previousTargetName != selection.name,
           let previousTargetHash
        {
            let previousTarget = managedHome.appendingPathComponent(previousTargetName)
            try removeRegularFile(
                previousTarget,
                expectedHash: previousTargetHash,
                fileManager: fileManager
            )
            try checkpoint?(.afterPreviousTargetRemoval)
        }

        try writeReceipt(committedReceipt(name: selection.name, hash: sourceHash), to: sidecar)
        return .projected(source: selection.url, target: target)
    }

    static func inspect(
        managedHome: URL,
        ordinaryHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default
    ) -> State {
        let diagnostic = diagnostic(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome,
            fileManager: fileManager
        )
        switch diagnostic.status {
        case let .current(sourceName):
            return .projected(
                source: ordinaryHome.appendingPathComponent(sourceName),
                target: managedHome.appendingPathComponent(sourceName)
            )
        case .absent:
            return .absent(managedHome: managedHome)
        case .conflict, .error:
            return .conflict(message: diagnostic.message)
        }
    }

    static func diagnostic(
        managedHome: URL,
        ordinaryHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default
    ) -> Diagnostic {
        do {
            try requireDirectoryChainWithoutSymbolicLink(
                ordinaryHome,
                label: "ordinary Codex home",
                allowMissing: true,
                ancestorDepth: 1
            )
            let selection = try effectiveSource(in: ordinaryHome)
            if try nodeType(at: managedHome) == nil {
                try requireDirectoryChainWithoutSymbolicLink(
                    managedHome,
                    label: "managed Codex home",
                    allowMissing: true,
                    ancestorDepth: 3
                )
                return Diagnostic(
                    status: .absent,
                    message: selection == nil
                        ? "No ordinary global Codex instruction file is present."
                        : "Global instructions are available and will be projected before the next Codex launch."
                )
            }
            try requireDirectoryChainWithoutSymbolicLink(
                managedHome,
                label: "managed Codex home",
                ancestorDepth: 3
            )

            let sidecar = managedHome.appendingPathComponent(sidecarName)
            let receipt = try loadReceipt(at: sidecar)
            let hashes = try targetHashes(in: managedHome)
            if let receipt, receipt.phase == .pending {
                return Diagnostic(
                    status: .conflict,
                    message: "A previous instruction projection was interrupted. RepoPrompt preserved its recoverable state and will reconcile it before the next Codex launch."
                )
            }

            guard let selection else {
                if receipt == nil, hashes.isEmpty {
                    return Diagnostic(
                        status: .absent,
                        message: "No ordinary global Codex instruction file is present."
                    )
                }
                return Diagnostic(
                    status: .conflict,
                    message: "No ordinary global instruction source is present, but projection state remains in the managed home. RepoPrompt will reconcile it before launch."
                )
            }

            guard let receipt else {
                return Diagnostic(
                    status: hashes.isEmpty ? .absent : .conflict,
                    message: hashes.isEmpty
                        ? "Global instructions are available and will be projected before the next Codex launch."
                        : "A managed-home instruction file is not owned by RepoPrompt and was preserved."
                )
            }
            try validateCommittedReceipt(receipt, hashes: hashes)
            let sourceData = try readStableRegularFile(selection.url, label: "ordinary \(selection.name)")
            guard receipt.sourceName == selection.name,
                  receipt.targetName == selection.name,
                  receipt.projectedHash == digest(sourceData)
            else {
                return Diagnostic(
                    status: .conflict,
                    message: "The ordinary global instruction source changed after the last projection. RepoPrompt will refresh it before the next Codex launch."
                )
            }
            return Diagnostic(
                status: .current(sourceName: selection.name),
                message: "The effective ordinary global \(selection.name) is currently projected as a RepoPrompt-owned regular file."
            )
        } catch {
            return diagnostic(for: error)
        }
    }

    static func diagnostic(for error: Error) -> Diagnostic {
        if let projectionError = error as? ProjectionError {
            return Diagnostic(status: .conflict, message: projectionError.privacyBoundedDiagnostic)
        }
        return Diagnostic(
            status: .error,
            message: "RepoPrompt could not inspect the global-instruction projection. Check managed-home permissions, then reconnect Codex."
        )
    }

    private static func effectiveSource(in ordinaryHome: URL) throws -> (name: String, url: URL)? {
        guard try nodeType(at: ordinaryHome) != nil else { return nil }
        for name in [overrideName, fallbackName] {
            let candidate = ordinaryHome.appendingPathComponent(name, isDirectory: false)
            guard try nodeType(at: candidate) != nil else { continue }
            try requireRegularFile(candidate, label: "ordinary \(name)")
            return (name, candidate)
        }
        return nil
    }

    private static func recoverInterruptedProjection(
        _ receipt: Receipt,
        managedHome: URL,
        sidecar: URL,
        fileManager: FileManager
    ) throws -> Receipt? {
        let hashes = try targetHashes(in: managedHome)
        if receipt.effectiveOperation == .remove {
            guard Set(hashes.keys).isSubset(of: Set([receipt.targetName])) else {
                throw ProjectionError.foreignTarget(
                    "Preserving an instruction file outside the interrupted removal receipt."
                )
            }
            if let actualHash = hashes[receipt.targetName] {
                guard actualHash == receipt.projectedHash else {
                    throw ProjectionError.modifiedProjection(
                        "The projection changed during interrupted removal."
                    )
                }
                try removeRegularFile(
                    managedHome.appendingPathComponent(receipt.targetName),
                    expectedHash: receipt.projectedHash,
                    fileManager: fileManager
                )
            }
            try removeRegularSidecarIfPresent(sidecar, fileManager: fileManager)
            return nil
        }

        let previousName = receipt.previousTargetName
            ?? (receipt.previousTargetHash == nil ? nil : receipt.targetName)
        let ownedNames = Set([receipt.targetName, previousName].compactMap(\.self))
        guard Set(hashes.keys).isSubset(of: ownedNames) else {
            throw ProjectionError.foreignTarget(
                "Preserving an instruction file outside the interrupted projection receipt."
            )
        }

        let currentHash = hashes[receipt.targetName]
        if currentHash == receipt.projectedHash {
            if let previousName,
               previousName != receipt.targetName,
               let previousHash = receipt.previousTargetHash,
               let actualPreviousHash = hashes[previousName]
            {
                guard actualPreviousHash == previousHash else {
                    throw ProjectionError.modifiedProjection(
                        "The previous projection changed during interrupted source switching."
                    )
                }
                try removeRegularFile(
                    managedHome.appendingPathComponent(previousName),
                    expectedHash: previousHash,
                    fileManager: fileManager
                )
            }
            let committed = committedReceipt(name: receipt.targetName, hash: receipt.projectedHash)
            try writeReceipt(committed, to: sidecar)
            return committed
        }

        if previousName == receipt.targetName,
           let previousHash = receipt.previousTargetHash,
           currentHash == previousHash
        {
            let committed = committedReceipt(name: receipt.targetName, hash: previousHash)
            try writeReceipt(committed, to: sidecar)
            return committed
        }

        if let previousName,
           previousName != receipt.targetName,
           let previousHash = receipt.previousTargetHash,
           currentHash == nil,
           hashes[previousName] == previousHash
        {
            let committed = committedReceipt(name: previousName, hash: previousHash)
            try writeReceipt(committed, to: sidecar)
            return committed
        }

        if previousName == nil, currentHash == nil, hashes.isEmpty {
            try removeRegularSidecarIfPresent(sidecar, fileManager: fileManager)
            return nil
        }

        throw ProjectionError.modifiedProjection(
            "The interrupted instruction projection no longer matches its ownership receipt."
        )
    }

    private static func validateCommittedReceipt(
        _ receipt: Receipt,
        hashes: [String: String]
    ) throws {
        guard receipt.phase == .committed else {
            throw ProjectionError.invalidSidecar("Expected a committed projection receipt.")
        }
        guard hashes[receipt.targetName] == receipt.projectedHash else {
            throw ProjectionError.modifiedProjection(
                "The owned instruction projection is missing or modified."
            )
        }
        guard Set(hashes.keys) == Set([receipt.targetName]) else {
            throw ProjectionError.foreignTarget(
                "Preserving an additional managed-home instruction file not owned by the receipt."
            )
        }
    }

    private static func targetHashes(in managedHome: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for name in [overrideName, fallbackName] {
            let target = managedHome.appendingPathComponent(name)
            guard try nodeType(at: target) != nil else { continue }
            do {
                hashes[name] = try hashOfRegularFile(target)
            } catch {
                throw ProjectionError.foreignTarget(
                    "Preserving a non-regular or symbolic-link managed-home instruction target."
                )
            }
        }
        return hashes
    }

    private static func committedReceipt(name: String, hash: String) -> Receipt {
        Receipt(
            schemaVersion: 2,
            owner: owner,
            sourceName: name,
            targetName: name,
            previousTargetName: nil,
            previousTargetHash: nil,
            projectedHash: hash,
            phase: .committed,
            operation: .project
        )
    }

    private static func loadReceipt(at url: URL) throws -> Receipt? {
        guard try nodeType(at: url) != nil else { return nil }
        do {
            try requireRegularFile(url, label: "projection receipt")
        } catch {
            throw ProjectionError.invalidSidecar(
                "The RepoPrompt projection receipt is not a regular file."
            )
        }
        let receipt: Receipt
        do {
            receipt = try JSONDecoder().decode(
                Receipt.self,
                from: readStableRegularFile(url, label: "projection receipt")
            )
        } catch let error as ProjectionError {
            throw error
        } catch {
            throw ProjectionError.invalidSidecar("Invalid RepoPrompt projection receipt.")
        }
        let validPreviousName = receipt.previousTargetName.map {
            [overrideName, fallbackName].contains($0)
        } ?? true
        let validPreviousHash = receipt.previousTargetHash.map(isValidHash) ?? true
        guard [1, 2].contains(receipt.schemaVersion),
              receipt.owner == owner,
              [overrideName, fallbackName].contains(receipt.sourceName),
              receipt.sourceName == receipt.targetName,
              validPreviousName,
              validPreviousHash,
              isValidHash(receipt.projectedHash),
              receipt.phase == .pending || (receipt.previousTargetName == nil && receipt.previousTargetHash == nil),
              receipt.phase == .pending || receipt.effectiveOperation == .project
        else {
            throw ProjectionError.invalidSidecar("Unrecognized RepoPrompt projection receipt.")
        }
        return receipt
    }

    private static func writeReceipt(_ receipt: Receipt, to url: URL) throws {
        if try nodeType(at: url) != nil {
            do {
                try requireRegularFile(url, label: "projection receipt")
            } catch {
                throw ProjectionError.invalidSidecar(
                    "Preserving a non-regular or symbolic-link projection receipt."
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
        do {
            try requireRegularFile(url, label: "projection receipt")
        } catch {
            throw ProjectionError.invalidSidecar("Projection receipt write did not produce a regular file.")
        }
    }

    private static func prepareManagedHome(_ managedHome: URL, fileManager: FileManager) throws {
        let parent = managedHome.deletingLastPathComponent()
        try requireDirectoryChainWithoutSymbolicLink(
            parent,
            label: "managed Codex state parent",
            ancestorDepth: 2
        )
        switch try nodeType(at: managedHome) {
        case nil:
            try fileManager.createDirectory(at: managedHome, withIntermediateDirectories: false)
        case mode_t(S_IFDIR):
            break
        default:
            throw ProjectionError.invalidSource(
                "The managed Codex home must be a real directory."
            )
        }
        try requireDirectoryChainWithoutSymbolicLink(
            managedHome,
            label: "managed Codex home",
            ancestorDepth: 3
        )
    }

    private static func removeRegularFile(
        _ url: URL,
        expectedHash: String,
        fileManager: FileManager
    ) throws {
        guard try hashOfRegularFile(url) == expectedHash else {
            throw ProjectionError.modifiedProjection(
                "Preserving a modified managed instruction projection."
            )
        }
        try fileManager.removeItem(at: url)
    }

    private static func removeRegularSidecarIfPresent(
        _ sidecar: URL,
        fileManager: FileManager
    ) throws {
        guard try nodeType(at: sidecar) != nil else { return }
        do {
            try requireRegularFile(sidecar, label: "projection receipt")
        } catch {
            throw ProjectionError.invalidSidecar(
                "Preserving a non-regular or symbolic-link projection receipt."
            )
        }
        try fileManager.removeItem(at: sidecar)
    }

    private static func hashOfRegularFile(_ url: URL) throws -> String {
        try digest(readStableRegularFile(url, label: "managed instruction projection"))
    }

    private static func readStableRegularFile(_ url: URL, label: String) throws -> Data {
        let before = try requireRegularFile(url, label: label)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let after = try requireRegularFile(url, label: label)
        guard FileIdentity(before) == FileIdentity(after), Int64(data.count) == after.st_size else {
            throw ProjectionError.invalidSource(
                "The \(label) changed while RepoPrompt was reading it."
            )
        }
        return data
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || (character >= "a" && character <= "f")
        }
    }

    @discardableResult
    private static func requireRegularFile(_ url: URL, label: String) throws -> stat {
        guard let status = try lstatStatus(at: url),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw ProjectionError.invalidSource(
                "The \(label) must be a regular file and not a symbolic link."
            )
        }
        return status
    }

    private static func requireDirectoryChainWithoutSymbolicLink(
        _ url: URL,
        label: String,
        allowMissing: Bool = false,
        ancestorDepth: Int
    ) throws {
        var candidate = url.standardizedFileURL
        for depth in 0 ... ancestorDepth {
            guard let status = try lstatStatus(at: candidate) else {
                if allowMissing {
                    candidate.deleteLastPathComponent()
                    continue
                }
                throw ProjectionError.invalidSource("Missing \(label).")
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw ProjectionError.invalidSource(
                    "The \(label) and its RepoPrompt-owned ancestors must be real directories."
                )
            }
            candidate.deleteLastPathComponent()
        }
    }

    private static func nodeType(at url: URL) throws -> mode_t? {
        try lstatStatus(at: url)?.st_mode.mapType
    }

    private static func lstatStatus(at url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 { return status }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return nil
    }
}

private extension mode_t {
    var mapType: mode_t {
        self & mode_t(S_IFMT)
    }
}
