import Darwin
import Foundation

enum WorkspaceCodemapLocalGitClassification: Equatable {
    case definitelyNonGit(WorkspaceCodemapNonGitFilesystemProof)
    case requiresGitPreflight
}

/// Result of re-observing a retained non-Git filesystem proof.
///
/// A freshly produced proof is itself definite non-Git evidence, so the only question left is
/// whether it still describes the same semantic binding. Ctime or permission churn refreshes the
/// proof in place; a different device/inode/file type is a real binding change that must revoke
/// serving rather than quietly continue on the old evidence.
///
/// Failing to observe the proof at all is neither of those: `unavailable` reports that the
/// evidence could not be read (for example a lost search permission on the root or an ancestor),
/// which must stop serving without claiming the binding changed.
enum WorkspaceCodemapNonGitFilesystemProofRefresh: Equatable {
    case current(WorkspaceCodemapNonGitFilesystemProof)
    case bindingChanged(WorkspaceCodemapNonGitFilesystemProof)
    case requiresGitPreflight
    case unavailable

    var currentProof: WorkspaceCodemapNonGitFilesystemProof? {
        guard case let .current(proof) = self else { return nil }
        return proof
    }
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
    let refresh: @Sendable (
        WorkspaceCodemapNonGitFilesystemProof
    ) -> WorkspaceCodemapNonGitFilesystemProofRefresh

    init(
        _ resolve: @escaping @Sendable (URL) async -> WorkspaceCodemapLocalGitClassification,
        refresh: @escaping @Sendable (
            WorkspaceCodemapNonGitFilesystemProof
        ) -> WorkspaceCodemapNonGitFilesystemProofRefresh = {
            WorkspaceCodemapLocalGitClassificationProbe.refreshProof($0)
        }
    ) {
        self.resolve = resolve
        self.refresh = refresh
    }

    static let production = Self { rootURL in
        classify(rootURL)
    }

    /// Why a definite non-Git proof could not be produced.
    ///
    /// Admission treats both failures the same way — Git preflight decides — but revalidation must
    /// not, because only `gitEvidence` establishes that the root stopped being a filesystem root.
    private enum ProofObservation {
        case proof(WorkspaceCodemapNonGitFilesystemProof)
        /// Positive `.git` or bare-repository evidence at the root or an ancestor.
        case gitEvidence
        /// The proof itself could not be observed: permission, missing path, or bounded-walk limit.
        case unobservable
    }

    private static func classify(_ rootURL: URL) -> WorkspaceCodemapLocalGitClassification {
        switch observeProof(rootURL) {
        case let .proof(proof):
            .definitelyNonGit(proof)
        case .gitEvidence, .unobservable:
            .requiresGitPreflight
        }
    }

    /// Reclassifies locally before deciding a changed witness needs a Git process: ancestor ctime
    /// churn does not mean Git exists, and losing read access does not mean the binding moved.
    private static func refreshProof(
        _ proof: WorkspaceCodemapNonGitFilesystemProof
    ) -> WorkspaceCodemapNonGitFilesystemProofRefresh {
        let rootURL = URL(fileURLWithPath: proof.requestedRootPath, isDirectory: true)
        switch observeProof(rootURL) {
        case let .proof(currentProof):
            return proofHasSameTopology(proof, currentProof)
                ? .current(currentProof)
                : .bindingChanged(currentProof)
        case .gitEvidence:
            return .requiresGitPreflight
        case .unobservable:
            return .unavailable
        }
    }

    /// Semantic binding identity: requested/resolved loaded paths plus witness device, inode, file
    /// type and symlink target. Directory ctime and ordinary contents are deliberately excluded.
    static func proofHasSameTopology(
        _ previous: WorkspaceCodemapNonGitFilesystemProof,
        _ current: WorkspaceCodemapNonGitFilesystemProof
    ) -> Bool {
        guard previous.requestedRootPath == current.requestedRootPath,
              previous.resolvedRootPath == current.resolvedRootPath,
              previous.lexicalPathWitnesses.count == current.lexicalPathWitnesses.count,
              previous.ancestorWitnesses.count == current.ancestorWitnesses.count
        else { return false }

        let lexicalTopologyMatches = zip(
            previous.lexicalPathWitnesses,
            current.lexicalPathWitnesses
        ).allSatisfy { previousWitness, currentWitness in
            previousWitness.path == currentWitness.path &&
                identitiesHaveSameTopology(previousWitness.identity, currentWitness.identity)
        }
        guard lexicalTopologyMatches else { return false }

        return zip(previous.ancestorWitnesses, current.ancestorWitnesses).allSatisfy {
            previousWitness, currentWitness in
            previousWitness.path == currentWitness.path &&
                identitiesHaveSameTopology(
                    previousWitness.directoryIdentity,
                    currentWitness.directoryIdentity
                ) &&
                entryWitnessesHaveSameTopology(previousWitness.dotGit, currentWitness.dotGit) &&
                entryWitnessesHaveSameTopology(previousWitness.head, currentWitness.head) &&
                entryWitnessesHaveSameTopology(previousWitness.objects, currentWitness.objects) &&
                entryWitnessesHaveSameTopology(previousWitness.refs, currentWitness.refs)
        }
    }

    /// Control entries are individually insufficient repository evidence: bare evidence requires
    /// `HEAD` plus either `objects` or `refs`, and a fresh proof already refuses `.git` or that
    /// combination. So their incidental metadata — ctime and permission churn on a legitimate
    /// non-Git directory of the same name — must not read as a binding change. Positive Git or
    /// bare evidence in the fresh observation remains the only reason to leave filesystem mode.
    private static func entryWitnessesHaveSameTopology(
        _ previous: WorkspaceCodemapNonGitFilesystemProof.EntryWitness,
        _ current: WorkspaceCodemapNonGitFilesystemProof.EntryWitness
    ) -> Bool {
        switch (previous, current) {
        case (.absent, .absent):
            true
        case let (.present(previousIdentity), .present(currentIdentity)):
            identitiesHaveSameTopology(previousIdentity, currentIdentity)
        default:
            false
        }
    }

    /// Topology is the file type, not its permission bits. A `chmod` on the root or an ancestor
    /// leaves the same object at the same place, so it must lead to local reclassification and a
    /// fresh access proof rather than a Git preflight. Control entries (`.git`, `HEAD`, `objects`,
    /// `refs`) are compared by presence and the same topology rule; real Git evidence never slips
    /// through because a fresh proof refuses `.git` or bare-repository evidence outright.
    private static func identitiesHaveSameTopology(
        _ previous: WorkspaceCodemapNonGitFilesystemProof.FileIdentity,
        _ current: WorkspaceCodemapNonGitFilesystemProof.FileIdentity
    ) -> Bool {
        previous.device == current.device &&
            previous.inode == current.inode &&
            (previous.mode & UInt32(S_IFMT)) == (current.mode & UInt32(S_IFMT)) &&
            previous.symlinkTarget == current.symlinkTarget
    }

    private static func observeProof(_ rootURL: URL) -> ProofObservation {
        let rootPath = rootURL.standardizedFileURL.path
        guard rootURL.isFileURL,
              rootPath.hasPrefix("/"),
              rootPath.utf8.count <= Int(PATH_MAX),
              let lexicalPathWitnesses = lexicalPathWitnesses(rootPath),
              lexicalPathWitnesses.count <= 512,
              let rootIdentity = lexicalPathWitnesses.last?.identity,
              (rootIdentity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        else {
            return .unobservable
        }

        guard let resolvedRootPath = resolvedPath(rootPath),
              resolvedRootPath.hasPrefix("/"),
              resolvedRootPath.utf8.count <= Int(PATH_MAX)
        else {
            return .unobservable
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
                return .unobservable
            }

            guard dotGit == .absent,
                  !resemblesBareRepository(head: head, objects: objects, refs: refs)
            else {
                return .gitEvidence
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

        return .proof(.init(
            requestedRootPath: rootPath,
            resolvedRootPath: resolvedRootPath,
            lexicalPathWitnesses: lexicalPathWitnesses,
            ancestorWitnesses: ancestorWitnesses
        ))
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
            device: safeDeviceID(info.st_dev),
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
