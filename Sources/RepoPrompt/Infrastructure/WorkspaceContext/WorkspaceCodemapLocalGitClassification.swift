import Darwin
import Foundation

enum WorkspaceCodemapLocalGitClassification: Equatable {
    case definitelyNonGit(WorkspaceCodemapNonGitFilesystemProof)
    case requiresGitPreflight
}

struct WorkspaceCodemapNonGitFilesystemProof: Equatable {
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let changeTimeSeconds: Int64
        let changeTimeNanoseconds: Int64
        let symlinkTarget: String?
    }

    struct PathWitness: Equatable {
        let path: String
        let identity: FileIdentity
    }

    enum EntryWitness: Equatable {
        case absent
        case present(FileIdentity)
    }

    struct AncestorWitness: Equatable {
        let path: String
        let directoryIdentity: FileIdentity
        let dotGit: EntryWitness
        let head: EntryWitness
        let objects: EntryWitness
        let refs: EntryWitness
    }

    let requestedRootPath: String
    let resolvedRootPath: String
    let lexicalPathWitnesses: [PathWitness]
    let ancestorWitnesses: [AncestorWitness]
}

struct WorkspaceCodemapLocalGitClassificationProbe {
    let resolve: @Sendable (URL) async -> WorkspaceCodemapLocalGitClassification
    let validate: @Sendable (WorkspaceCodemapNonGitFilesystemProof) -> Bool

    init(
        _ resolve: @escaping @Sendable (URL) async -> WorkspaceCodemapLocalGitClassification,
        validate: @escaping @Sendable (WorkspaceCodemapNonGitFilesystemProof) -> Bool = {
            WorkspaceCodemapLocalGitClassificationProbe.proofIsCurrent($0)
        }
    ) {
        self.resolve = resolve
        self.validate = validate
    }

    static let production = Self { rootURL in
        classify(rootURL)
    }

    private static func classify(_ rootURL: URL) -> WorkspaceCodemapLocalGitClassification {
        guard let proof = makeProof(rootURL) else {
            return .requiresGitPreflight
        }
        return .definitelyNonGit(proof)
    }

    private static func proofIsCurrent(_ proof: WorkspaceCodemapNonGitFilesystemProof) -> Bool {
        let rootURL = URL(fileURLWithPath: proof.requestedRootPath, isDirectory: true)
        return makeProof(rootURL) == proof
    }

    private static func makeProof(_ rootURL: URL) -> WorkspaceCodemapNonGitFilesystemProof? {
        let rootPath = rootURL.standardizedFileURL.path
        guard rootURL.isFileURL,
              rootPath.hasPrefix("/"),
              rootPath.utf8.count <= Int(PATH_MAX),
              let lexicalPathWitnesses = lexicalPathWitnesses(rootPath),
              lexicalPathWitnesses.count <= 512,
              let rootIdentity = lexicalPathWitnesses.last?.identity,
              (rootIdentity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        else {
            return nil
        }

        guard let resolvedRootPath = resolvedPath(rootPath),
              resolvedRootPath.hasPrefix("/"),
              resolvedRootPath.utf8.count <= Int(PATH_MAX)
        else {
            return nil
        }

        var ancestorWitnesses: [WorkspaceCodemapNonGitFilesystemProof.AncestorWitness] = []
        var candidatePath = resolvedRootPath
        while true {
            let candidate = NSString(string: candidatePath)
            guard ancestorWitnesses.count < 512,
                  let directoryIdentity = identity(atPath: candidatePath),
                  (directoryIdentity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR),
                  let dotGit = entryWitness(atPath: candidate.appendingPathComponent(".git")),
                  let head = entryWitness(atPath: candidate.appendingPathComponent("HEAD")),
                  let objects = entryWitness(atPath: candidate.appendingPathComponent("objects")),
                  let refs = entryWitness(atPath: candidate.appendingPathComponent("refs"))
            else {
                return nil
            }

            guard dotGit == .absent,
                  !resemblesBareRepository(head: head, objects: objects, refs: refs)
            else {
                return nil
            }
            ancestorWitnesses.append(.init(
                path: candidatePath,
                directoryIdentity: directoryIdentity,
                dotGit: dotGit,
                head: head,
                objects: objects,
                refs: refs
            ))

            let deleted = candidate.deletingLastPathComponent
            let parentPath = deleted.isEmpty ? "/" : deleted
            if parentPath == candidatePath {
                break
            }
            candidatePath = parentPath
        }

        return .init(
            requestedRootPath: rootPath,
            resolvedRootPath: resolvedRootPath,
            lexicalPathWitnesses: lexicalPathWitnesses,
            ancestorWitnesses: ancestorWitnesses
        )
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let value = String(cString: resolved)
        return value.utf8.count <= Int(PATH_MAX) ? value : nil
    }

    private static func lexicalPathWitnesses(
        _ rootPath: String
    ) -> [WorkspaceCodemapNonGitFilesystemProof.PathWitness]? {
        let components = NSString(string: rootPath).pathComponents
        guard !components.isEmpty, components.count <= 512 else { return nil }

        var witnesses: [WorkspaceCodemapNonGitFilesystemProof.PathWitness] = []
        var candidate = "/"
        for (index, component) in components.enumerated() {
            if index > 0 {
                candidate = URL(fileURLWithPath: candidate, isDirectory: true)
                    .appendingPathComponent(component)
                    .path
            }
            guard candidate.utf8.count <= Int(PATH_MAX),
                  let identity = identity(atPath: candidate)
            else {
                return nil
            }
            witnesses.append(.init(path: candidate, identity: identity))
        }
        return witnesses
    }

    private static func identity(
        atPath path: String
    ) -> WorkspaceCodemapNonGitFilesystemProof.FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }

        let fileType = info.st_mode & S_IFMT
        let symlinkTarget: String?
        if fileType == S_IFLNK {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                  target.utf8.count <= Int(PATH_MAX)
            else {
                return nil
            }
            symlinkTarget = target
        } else {
            symlinkTarget = nil
        }

        return .init(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            mode: UInt32(info.st_mode),
            changeTimeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeTimeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            symlinkTarget: symlinkTarget
        )
    }

    private static func entryWitness(
        atPath path: String
    ) -> WorkspaceCodemapNonGitFilesystemProof.EntryWitness? {
        if let identity = identity(atPath: path) {
            return .present(identity)
        }
        return errno == ENOENT || errno == ENOTDIR ? .absent : nil
    }

    private static func resemblesBareRepository(
        head: WorkspaceCodemapNonGitFilesystemProof.EntryWitness,
        objects: WorkspaceCodemapNonGitFilesystemProof.EntryWitness,
        refs: WorkspaceCodemapNonGitFilesystemProof.EntryWitness
    ) -> Bool {
        guard case .present = head else { return false }
        if case .present = objects { return true }
        if case .present = refs { return true }
        return false
    }
}
