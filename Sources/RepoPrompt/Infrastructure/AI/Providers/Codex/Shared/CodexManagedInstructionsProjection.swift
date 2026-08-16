import CryptoKit
import Foundation

/// Projects Codex's effective ordinary user-global instructions into RepoPrompt's isolated home.
/// The projection is one-way and only replaces or removes files whose ownership is proven by the sidecar.
enum CodexManagedInstructionsProjection {
    static let overrideName = "AGENTS.override.md"
    static let fallbackName = "AGENTS.md"
    static let sidecarName = ".repoprompt-global-instructions.json"
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
    }

    enum State: Equatable {
        case projected(source: URL, target: URL)
        case absent(managedHome: URL)
        case conflict(message: String)
    }

    private struct Receipt: Codable, Equatable {
        enum Phase: String, Codable { case pending, committed }

        let schemaVersion: Int
        let owner: String
        let sourceName: String
        let targetName: String
        let previousTargetHash: String?
        let projectedHash: String
        let phase: Phase
    }

    static func projectBeforeLaunch(
        managedHome: URL,
        ordinaryHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> State {
        lock.lock()
        defer { lock.unlock() }

        try fileManager.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try requireDirectoryWithoutSymbolicLink(managedHome, label: "managed Codex home", fileManager: fileManager)
        try requireDirectoryWithoutSymbolicLink(ordinaryHome, label: "ordinary Codex home", allowMissing: true, fileManager: fileManager)

        let selection = try effectiveSource(in: ordinaryHome, fileManager: fileManager)
        let sidecar = managedHome.appendingPathComponent(sidecarName, isDirectory: false)
        let existingReceipt = try loadReceipt(at: sidecar, fileManager: fileManager)

        guard let selection else {
            try removeOwnedProjectionIfPresent(
                managedHome: managedHome,
                sidecar: sidecar,
                receipt: existingReceipt,
                fileManager: fileManager
            )
            return .absent(managedHome: managedHome)
        }

        let target = managedHome.appendingPathComponent(selection.name, isDirectory: false)
        let otherName = selection.name == overrideName ? fallbackName : overrideName
        let otherTarget = managedHome.appendingPathComponent(otherName, isDirectory: false)
        try removeOwnedTargetIfNeeded(otherTarget, sidecar: sidecar, receipt: existingReceipt, fileManager: fileManager)

        let sourceData = try Data(contentsOf: selection.url, options: .mappedIfSafe)
        let sourceHash = digest(sourceData)
        let previousHash = try verifyOwnershipForReplacement(
            target: target,
            sidecar: sidecar,
            receipt: existingReceipt,
            nextHash: sourceHash,
            fileManager: fileManager
        )

        let pending = Receipt(
            schemaVersion: 1,
            owner: "com.repoprompt.ce.codex-global-instructions",
            sourceName: selection.name,
            targetName: selection.name,
            previousTargetHash: previousHash,
            projectedHash: sourceHash,
            phase: .pending
        )
        try writeReceipt(pending, to: sidecar)
        try sourceData.write(to: target, options: .atomic)
        try requireRegularFile(target, label: "managed instruction projection", fileManager: fileManager)
        try writeReceipt(
            Receipt(
                schemaVersion: pending.schemaVersion,
                owner: pending.owner,
                sourceName: pending.sourceName,
                targetName: pending.targetName,
                previousTargetHash: nil,
                projectedHash: pending.projectedHash,
                phase: .committed
            ),
            to: sidecar
        )
        return .projected(source: selection.url, target: target)
    }

    static func inspect(
        managedHome: URL,
        ordinaryHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default
    ) -> State {
        do {
            let selection = try effectiveSource(in: ordinaryHome, fileManager: fileManager)
            let receipt = try loadReceipt(
                at: managedHome.appendingPathComponent(sidecarName),
                fileManager: fileManager
            )
            guard let selection else { return .absent(managedHome: managedHome) }
            let target = managedHome.appendingPathComponent(selection.name)
            guard let receipt, receipt.phase == .committed,
                  receipt.sourceName == selection.name,
                  receipt.targetName == selection.name,
                  try hashOfRegularFile(target, fileManager: fileManager) == receipt.projectedHash
            else {
                return .conflict(message: "Global instruction projection is not current.")
            }
            return .projected(source: selection.url, target: target)
        } catch {
            return .conflict(message: error.localizedDescription)
        }
    }

    private static func effectiveSource(
        in ordinaryHome: URL,
        fileManager: FileManager
    ) throws -> (name: String, url: URL)? {
        for name in [overrideName, fallbackName] {
            let candidate = ordinaryHome.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            try requireRegularFile(candidate, label: "ordinary \(name)", fileManager: fileManager)
            return (name, candidate)
        }
        return nil
    }

    private static func verifyOwnershipForReplacement(
        target: URL,
        sidecar: URL,
        receipt: Receipt?,
        nextHash: String,
        fileManager: FileManager
    ) throws -> String? {
        guard fileManager.fileExists(atPath: target.path) else {
            if let receipt, receipt.targetName == target.lastPathComponent,
               receipt.phase == .pending, receipt.previousTargetHash != nil
            {
                throw ProjectionError.modifiedProjection("Owned projection disappeared during an interrupted update: \(target.path)")
            }
            return nil
        }
        guard let receipt else {
            throw ProjectionError.foreignTarget("Preserving foreign managed-home file without RepoPrompt ownership receipt: \(target.path)")
        }
        guard receipt.targetName == target.lastPathComponent else {
            throw ProjectionError.foreignTarget("Projection receipt does not own \(target.path)")
        }
        let actual = try hashOfRegularFile(target, fileManager: fileManager)
        let allowed = receipt.phase == .committed
            ? [receipt.projectedHash]
            : [receipt.previousTargetHash, receipt.projectedHash].compactMap(\.self)
        guard allowed.contains(actual) else {
            throw ProjectionError.modifiedProjection("Preserving modified managed instruction projection: \(target.path)")
        }
        _ = sidecar
        return actual == nextHash ? actual : actual
    }

    private static func removeOwnedProjectionIfPresent(
        managedHome: URL,
        sidecar: URL,
        receipt: Receipt?,
        fileManager: FileManager
    ) throws {
        guard let receipt else { return }
        let target = managedHome.appendingPathComponent(receipt.targetName)
        try removeOwnedTargetIfNeeded(target, sidecar: sidecar, receipt: receipt, fileManager: fileManager)
        if fileManager.fileExists(atPath: sidecar.path) { try fileManager.removeItem(at: sidecar) }
    }

    private static func removeOwnedTargetIfNeeded(
        _ target: URL,
        sidecar: URL,
        receipt: Receipt?,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: target.path) else { return }
        guard let receipt, receipt.targetName == target.lastPathComponent else {
            throw ProjectionError.foreignTarget("Preserving foreign managed-home file: \(target.path)")
        }
        let actual = try hashOfRegularFile(target, fileManager: fileManager)
        let allowed = receipt.phase == .committed
            ? [receipt.projectedHash]
            : [receipt.previousTargetHash, receipt.projectedHash].compactMap(\.self)
        guard allowed.contains(actual) else {
            throw ProjectionError.modifiedProjection("Preserving modified managed instruction projection: \(target.path)")
        }
        try fileManager.removeItem(at: target)
        _ = sidecar
    }

    private static func loadReceipt(at url: URL, fileManager: FileManager) throws -> Receipt? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try requireRegularFile(url, label: "projection receipt", fileManager: fileManager)
        let receipt: Receipt
        do { receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url)) }
        catch { throw ProjectionError.invalidSidecar("Invalid RepoPrompt projection receipt at \(url.path)") }
        guard receipt.schemaVersion == 1,
              receipt.owner == "com.repoprompt.ce.codex-global-instructions",
              [overrideName, fallbackName].contains(receipt.sourceName),
              receipt.sourceName == receipt.targetName,
              receipt.projectedHash.count == 64,
              receipt.projectedHash.allSatisfy(\.isHexDigit)
        else { throw ProjectionError.invalidSidecar("Unrecognized RepoPrompt projection receipt at \(url.path)") }
        return receipt
    }

    private static func writeReceipt(_ receipt: Receipt, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }

    private static func hashOfRegularFile(_ url: URL, fileManager: FileManager) throws -> String {
        try requireRegularFile(url, label: "managed instruction projection", fileManager: fileManager)
        return try digest(Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func requireRegularFile(_ url: URL, label: String, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProjectionError.invalidSource("The \(label) must be a regular file: \(url.path)")
        }
    }

    private static func requireDirectoryWithoutSymbolicLink(
        _ url: URL,
        label: String,
        allowMissing: Bool = false,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            if allowMissing { return }
            throw ProjectionError.invalidSource("Missing \(label): \(url.path)")
        }
        guard isDirectory.boolValue,
              try (fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
        else { throw ProjectionError.invalidSource("The \(label) must be a real directory: \(url.path)") }
    }
}
