import CryptoKit
import Darwin
import Foundation

enum CodexGlobalInstructionsProjection {
    enum Failure: Error, LocalizedError {
        case sourceUnreadable(URL, String)
        case manifestInvalid(URL, String)
        case unownedDestination(URL)
        case modifiedDestination(URL)
        case unsupportedDestination(URL, String)
        case inspectionFailed(URL, String)
        case destinationMutationFailed(URL, String)
        case manifestMutationFailed(URL, String)

        var errorDescription: String? {
            switch self {
            case let .sourceUnreadable(url, detail):
                "RepoPrompt could not read the global Codex instruction file at `\(url.path)` (\(detail)). Neither managed instruction file was changed."
            case let .manifestInvalid(url, detail):
                "RepoPrompt could not use its Codex instruction projection manifest at `\(url.path)` (\(detail)). Neither managed instruction file was changed. Preserve anything needed, move or remove the manifest, and try again."
            case let .unownedDestination(url):
                "RepoPrompt found an unowned Codex instruction file at `\(url.path)`. It was preserved and neither managed instruction file was changed. Preserve anything needed, move or remove the file, and try again."
            case let .modifiedDestination(url):
                "RepoPrompt found a modified managed Codex instruction file at `\(url.path)`. It was preserved and neither managed instruction file was changed. Preserve anything needed, move or remove the file, and try again."
            case let .unsupportedDestination(url, kind):
                "RepoPrompt found a \(kind) at managed Codex instruction path `\(url.path)`. It was preserved and neither managed instruction file was changed. Preserve anything needed, move or remove the entry, and try again."
            case let .inspectionFailed(url, detail):
                "RepoPrompt could not inspect Codex instruction state at `\(url.path)` (\(detail)). Neither managed instruction file was changed."
            case let .destinationMutationFailed(url, detail):
                "RepoPrompt could not update the managed Codex instruction file at `\(url.path)` (\(detail)). Try again so RepoPrompt can reconcile the managed projection."
            case let .manifestMutationFailed(url, detail):
                "RepoPrompt could not update its Codex instruction projection manifest at `\(url.path)` (\(detail)). Try again so RepoPrompt can reconcile the managed projection."
            }
        }
    }

    private struct InstructionFile {
        let name: String
    }

    private struct SourceSnapshot {
        let data: Data
        let hash: String
    }

    private enum DestinationSnapshot {
        case missing
        case regular(hash: String)
        case symbolicLink
        case unsupported(String)
    }

    private enum DestinationAction {
        case none
        case write(Data)
        case remove
    }

    private struct ProjectionAction {
        let file: InstructionFile
        let destination: URL
        let action: DestinationAction
        let desiredHash: String?
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let projectedFileHashes: [String: String]
    }

    private static let files = [
        InstructionFile(name: "AGENTS.override.md"),
        InstructionFile(name: "AGENTS.md")
    ]
    private static let manifestName = ".repoprompt-agents-projection.json"
    private static let lock = NSLock()

    static func prepare(
        ordinaryCodexHome: URL,
        managedCodexHome: URL,
        fileManager: FileManager = .default
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let sourceSnapshots = try Dictionary(uniqueKeysWithValues: files.map { file in
            let source = ordinaryCodexHome.appendingPathComponent(file.name)
            return try (file.name, sourceSnapshot(at: source))
        })
        let manifestURL = managedCodexHome.appendingPathComponent(manifestName)
        let previousManifest = try loadManifest(at: manifestURL)

        let actions = try files.map { file in
            let destination = managedCodexHome.appendingPathComponent(file.name)
            let destinationSnapshot = try destinationSnapshot(at: destination)
            return try projectionAction(
                file: file,
                destination: destination,
                source: sourceSnapshots[file.name] ?? nil,
                destinationSnapshot: destinationSnapshot,
                manifestHash: previousManifest?.projectedFileHashes[file.name]
            )
        }

        for action in actions {
            try apply(action, fileManager: fileManager)
        }

        let projectedFileHashes = Dictionary(uniqueKeysWithValues: actions.compactMap { action in
            action.desiredHash.map { (action.file.name, $0) }
        })
        try commitManifest(projectedFileHashes, at: manifestURL, fileManager: fileManager)
    }

    private static func sourceSnapshot(at url: URL) throws -> SourceSnapshot? {
        var metadata = Darwin.stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &metadata)
        }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw Failure.inspectionFailed(url, posixErrorDescription())
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return SourceSnapshot(data: data, hash: hash(data))
        } catch {
            throw Failure.sourceUnreadable(url, error.localizedDescription)
        }
    }

    private static func destinationSnapshot(at url: URL) throws -> DestinationSnapshot {
        var metadata = Darwin.stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return .missing }
            throw Failure.inspectionFailed(url, posixErrorDescription())
        }

        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            do {
                return try .regular(hash: hash(Data(contentsOf: url)))
            } catch {
                throw Failure.inspectionFailed(url, error.localizedDescription)
            }
        case S_IFLNK:
            return .symbolicLink
        case S_IFDIR:
            return .unsupported("directory")
        default:
            return .unsupported("non-regular filesystem entry")
        }
    }

    private static func loadManifest(at url: URL) throws -> Manifest? {
        switch try destinationSnapshot(at: url) {
        case .missing:
            return nil
        case .symbolicLink:
            throw Failure.manifestInvalid(url, "the manifest is a symbolic link")
        case let .unsupported(kind):
            throw Failure.manifestInvalid(url, "the manifest is a \(kind)")
        case .regular:
            break
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        } catch {
            throw Failure.manifestInvalid(url, error.localizedDescription)
        }
        guard manifest.schemaVersion == 1 else {
            throw Failure.manifestInvalid(url, "unsupported schema version \(manifest.schemaVersion)")
        }

        let allowedNames = Set(files.map(\.name))
        guard Set(manifest.projectedFileHashes.keys).isSubset(of: allowedNames) else {
            throw Failure.manifestInvalid(url, "the manifest contains an unknown filename")
        }
        guard manifest.projectedFileHashes.values.allSatisfy(isValidHash) else {
            throw Failure.manifestInvalid(url, "the manifest contains an invalid SHA-256 hash")
        }
        return manifest
    }

    private static func projectionAction(
        file: InstructionFile,
        destination: URL,
        source: SourceSnapshot?,
        destinationSnapshot: DestinationSnapshot,
        manifestHash: String?
    ) throws -> ProjectionAction {
        switch destinationSnapshot {
        case .missing:
            if let source {
                return ProjectionAction(file: file, destination: destination, action: .write(source.data), desiredHash: source.hash)
            }
            return ProjectionAction(file: file, destination: destination, action: .none, desiredHash: nil)
        case .symbolicLink:
            throw Failure.unsupportedDestination(destination, "symbolic link")
        case let .unsupported(kind):
            throw Failure.unsupportedDestination(destination, kind)
        case let .regular(destinationHash):
            guard let manifestHash else {
                throw Failure.unownedDestination(destination)
            }
            guard destinationHash == manifestHash else {
                if let source, destinationHash == source.hash {
                    return ProjectionAction(file: file, destination: destination, action: .none, desiredHash: source.hash)
                }
                throw Failure.modifiedDestination(destination)
            }
            guard let source else {
                return ProjectionAction(file: file, destination: destination, action: .remove, desiredHash: nil)
            }
            let action: DestinationAction = destinationHash == source.hash ? .none : .write(source.data)
            return ProjectionAction(file: file, destination: destination, action: action, desiredHash: source.hash)
        }
    }

    private static func apply(_ projection: ProjectionAction, fileManager: FileManager) throws {
        do {
            switch projection.action {
            case .none:
                return
            case let .write(data):
                try data.write(to: projection.destination, options: .atomic)
            case .remove:
                try fileManager.removeItem(at: projection.destination)
            }
        } catch {
            throw Failure.destinationMutationFailed(projection.destination, error.localizedDescription)
        }
    }

    private static func commitManifest(
        _ projectedFileHashes: [String: String],
        at url: URL,
        fileManager: FileManager
    ) throws {
        do {
            if projectedFileHashes.isEmpty {
                if case .missing = try destinationSnapshot(at: url) { return }
                try fileManager.removeItem(at: url)
                return
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Manifest(schemaVersion: 1, projectedFileHashes: projectedFileHashes))
            try data.write(to: url, options: .atomic)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.manifestMutationFailed(url, error.localizedDescription)
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidHash(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}
