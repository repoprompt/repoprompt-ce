import Darwin
import Foundation
import RepoPromptDomainRuntime

/// Carries the immutable path-fence guard into detached materialization work. The guard is a
/// value of admitted path identities whose `revalidate()` only reads the filesystem.
struct GitWorktreePhysicalMutationGuardBox: @unchecked Sendable {
    let value: DomainMutationPhysicalCommitGuard?
}

/// Why an app-managed worktree creation used an ordinary `git worktree add` checkout instead
/// of the tracked-file APFS clone fast path. Raw values are stable, path-free diagnostics.
enum GitWorktreeTrackedCloneIneligibility: String, Error, Equatable {
    case notRequested = "not-requested"
    case forceRequested = "force-requested"
    case destinationNotAppManaged = "destination-not-app-managed"
    case sourceLayoutUnavailable = "source-layout-unavailable"
    case protectedMutationWithoutCapability = "protected-mutation-without-capability"
    case volumeUnavailable = "volume-unavailable"
    case volumeNotAPFS = "volume-not-apfs"
    case volumeCloningUnsupported = "volume-cloning-unsupported"
    case differentVolume = "different-volume"
    case sparseCheckout = "sparse-checkout"
    case symlinksDisabled = "symlinks-disabled"
    case lineEndingConversion = "line-ending-conversion"
    case sourceHeadUnavailable = "source-head-unavailable"
    case baseTreeUnavailable = "base-tree-unavailable"
    case baseTreeMismatch = "base-tree-mismatch"
    case postCheckoutHook = "post-checkout-hook"
    case sourceHasTrackedChanges = "source-has-tracked-changes"
    case hiddenIndexState = "hidden-index-state"
    case emptyTree = "empty-tree"
    case submodule
    case unsupportedTreeEntry = "unsupported-tree-entry"
    case unsafeTreePath = "unsafe-tree-path"
    case pathFoldingCollision = "path-folding-collision"
    case checkoutAttributes = "checkout-attributes"
    case gitCommandFailed = "git-command-failed"
}

struct GitWorktreeTrackedTreeEntry: Equatable {
    enum Kind: Equatable {
        case regular
        case executable
        case symbolicLink
    }

    let kind: Kind
    let pathComponents: [String]
    let size: Int64
    let objectID: String

    var relativePath: String {
        pathComponents.joined(separator: "/")
    }
}

struct GitWorktreeTrackedMaterializationSummary: Equatable {
    var regularFileCount = 0
    var symbolicLinkCount = 0
    var byteCount: Int64 = 0
}

struct GitWorktreeTrackedMaterializationError: Error, CustomStringConvertible {
    let relativePath: String
    let outcome: GitWorktreeFileCloner.Outcome

    var description: String {
        "could not clone \(relativePath): \(outcome)"
    }
}

/// Pure helpers for the tracked-checkout clone fast path.
///
/// The fast path is deliberately conservative: it only runs when a fresh checkout of the
/// target tree is byte-for-byte what the clean source checkout already contains, and Git's
/// own index refresh re-hashes every cloned file before the result is accepted.
enum GitWorktreeTrackedCheckoutClone {
    struct VolumeProbe: Equatable {
        let caseSensitive: Bool
    }

    struct ConfigAssessment: Equatable {
        let ineligibility: GitWorktreeTrackedCloneIneligibility?
        let attributesFileConfigured: Bool
    }

    struct AttributeAssessment: Equatable {
        /// A checkout-time conversion (filter, encoding, ident, CRLF output) is configured.
        let blocksClone: Bool
        /// Paths whose clean conversion may normalize line endings. Git's index refresh
        /// compares the *converted* bytes, so these paths also need a raw byte comparison
        /// against the blob that an ordinary checkout would write.
        let rawByteVerificationPaths: [String]
    }

    /// Device and inode of a directory, used to pin the freshly created worktree root.
    struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    static func directoryIdentity(_ url: URL) -> DirectoryIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return nil }
        return DirectoryIdentity(device: status.st_dev, inode: status.st_ino)
    }

    /// Environment-based config overrides keep read-only Git commands classified as reads
    /// (so they run with `GIT_OPTIONAL_LOCKS=0`) while disabling caches that could hide
    /// working-tree differences.
    static let gitEnvironment: [String: String] = [
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "core.fsmonitor",
        "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "core.untrackedCache",
        "GIT_CONFIG_VALUE_1": "false"
    ]

    // MARK: - Volume

    static func probeVolumes(
        sourceRoot: URL,
        destination: URL
    ) -> Result<VolumeProbe, GitWorktreeTrackedCloneIneligibility> {
        var sourceStatus = statfs()
        guard statfs(sourceRoot.path, &sourceStatus) == 0,
              let anchor = nearestExistingAncestor(of: destination)
        else { return .failure(.volumeUnavailable) }
        var destinationStatus = statfs()
        guard statfs(anchor.path, &destinationStatus) == 0 else { return .failure(.volumeUnavailable) }
        guard fileSystemTypeName(sourceStatus) == "apfs",
              fileSystemTypeName(destinationStatus) == "apfs"
        else { return .failure(.volumeNotAPFS) }
        guard sourceStatus.f_fsid.val.0 == destinationStatus.f_fsid.val.0,
              sourceStatus.f_fsid.val.1 == destinationStatus.f_fsid.val.1
        else { return .failure(.differentVolume) }
        let values = try? sourceRoot.resourceValues(forKeys: [
            .volumeSupportsFileCloningKey,
            .volumeSupportsCaseSensitiveNamesKey
        ])
        guard values?.volumeSupportsFileCloning == true else { return .failure(.volumeCloningUnsupported) }
        return .success(VolumeProbe(caseSensitive: values?.volumeSupportsCaseSensitiveNames == true))
    }

    private static func fileSystemTypeName(_ status: statfs) -> String {
        var name = status.f_fstypename
        return withUnsafeBytes(of: &name) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func nearestExistingAncestor(of url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while true {
            var status = stat()
            if lstat(candidate.path, &status) == 0 { return candidate }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    // MARK: - Git output parsing

    /// Parses `git config --list -z`. Later entries win, matching Git's own precedence.
    static func assessConfig(_ output: String) -> ConfigAssessment {
        var values: [String: String?] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].lowercased()
            // A key without a value is Git's implicit boolean `true`; keep it as a nil value
            // rather than removing the key from the dictionary.
            values.updateValue(parts.count > 1 ? String(parts[1]) : nil, forKey: key)
        }
        func bool(_ key: String) -> Bool? {
            guard let entry = values[key] else { return nil }
            guard let raw = entry?.lowercased() else { return true }
            if ["true", "yes", "on"].contains(raw) { return true }
            if ["false", "no", "off", ""].contains(raw) { return false }
            return (Int(raw) ?? 0) != 0
        }

        let attributesFileConfigured = (values["core.attributesfile"] ?? nil)?.isEmpty == false
        let autocrlf = (values["core.autocrlf"] ?? nil)?.lowercased()
        let ineligibility: GitWorktreeTrackedCloneIneligibility? = if bool("core.sparsecheckout") == true {
            .sparseCheckout
        } else if bool("core.symlinks") == false {
            .symlinksDisabled
        } else if autocrlf == "input" || bool("core.autocrlf") == true {
            .lineEndingConversion
        } else if (values["core.eol"] ?? nil)?.lowercased() == "crlf" {
            .lineEndingConversion
        } else {
            nil
        }
        return ConfigAssessment(ineligibility: ineligibility, attributesFileConfigured: attributesFileConfigured)
    }

    /// `git ls-files -v -z`: every tracked entry must be plainly cached (`H`). Lowercase tags
    /// mark assume-unchanged, `S` marks skip-worktree, and `M` marks unmerged entries; each
    /// can hide a working-tree difference from `git status`.
    static func hasHiddenIndexState(_ lsFilesVerboseOutput: String) -> Bool {
        lsFilesVerboseOutput.split(separator: "\0", omittingEmptySubsequences: true).contains { record in
            !record.hasPrefix("H ")
        }
    }

    static let checkedAttributes = ["filter", "working-tree-encoding", "ident", "eol", "text"]

    /// Parses `git check-attr -z --stdin filter working-tree-encoding ident eol text`.
    ///
    /// Under the accepted configuration (no autocrlf, no CRLF `core.eol`) Git's checkout writes
    /// blob bytes unchanged, but `text`/`eol=lf` clean conversion can make CRLF working-tree
    /// bytes look clean. Those paths are returned for raw byte verification.
    static func assessCheckoutAttributes(_ checkAttrOutput: String) -> AttributeAssessment {
        let fields = checkAttrOutput.split(separator: "\0", omittingEmptySubsequences: false)
        var rawPaths: [String] = []
        var seenRawPaths = Set<Substring>()
        var index = 0
        while index + 2 < fields.count {
            let path = fields[index]
            let attribute = fields[index + 1]
            let value = fields[index + 2]
            index += 3
            if value == "unspecified" || value == "unset" { continue }
            switch attribute {
            case "text":
                break
            case "eol" where value == "lf":
                break
            default:
                return AttributeAssessment(blocksClone: true, rawByteVerificationPaths: [])
            }
            if seenRawPaths.insert(path).inserted { rawPaths.append(String(path)) }
        }
        return AttributeAssessment(blocksClone: false, rawByteVerificationPaths: rawPaths)
    }

    /// Parses `git ls-tree -r -z --full-tree <tree>` (sizes are optional: `-l` output with a
    /// fourth size column is accepted, but the fast path skips `-l` because it must read
    /// every blob header).
    static func parseTree(
        _ output: String,
        caseSensitiveVolume: Bool
    ) -> Result<[GitWorktreeTrackedTreeEntry], GitWorktreeTrackedCloneIneligibility> {
        var entries: [GitWorktreeTrackedTreeEntry] = []
        // Keys use Swift's canonical-equivalence string hashing plus optional case folding;
        // owners keep exact UTF-8 bytes because Swift `==` treats NFC/NFD spellings as equal.
        var foldedOwners: [String: [UInt8]] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { return .failure(.unsupportedTreeEntry) }
            let metadata = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            let path = record[record.index(after: tab)...]
            guard metadata.count == 3 || metadata.count == 4 else { return .failure(.unsupportedTreeEntry) }
            let kind: GitWorktreeTrackedTreeEntry.Kind
            switch metadata[0] {
            case "100644": kind = .regular
            case "100755": kind = .executable
            case "120000": kind = .symbolicLink
            case "160000": return .failure(.submodule)
            default: return .failure(.unsupportedTreeEntry)
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.allSatisfy(isSafeComponent) else { return .failure(.unsafeTreePath) }

            // APFS is normalization-insensitive and usually case-insensitive. Two tree paths
            // that name the same file would make a checkout dirty, so leave them to Git.
            for depth in 1 ... components.count {
                let original = components[0 ..< depth].joined(separator: "/")
                let originalBytes = Array(original.utf8)
                var folded = original.decomposedStringWithCanonicalMapping
                if !caseSensitiveVolume {
                    folded = folded.folding(options: [.caseInsensitive], locale: nil)
                }
                if let owner = foldedOwners[folded] {
                    guard owner == originalBytes else { return .failure(.pathFoldingCollision) }
                } else {
                    foldedOwners[folded] = originalBytes
                }
            }
            entries.append(GitWorktreeTrackedTreeEntry(
                kind: kind,
                pathComponents: components,
                size: metadata.count == 4 ? Int64(metadata[3]) ?? 0 : 0,
                objectID: String(metadata[2])
            ))
        }
        guard !entries.isEmpty else { return .failure(.emptyTree) }
        return .success(entries)
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        // Reject `.git` including HFS/APFS-ignorable Unicode spellings of it.
        let asciiFolded = String(String.UnicodeScalarView(component.unicodeScalars.filter(\.isASCII)))
        return asciiFolded.lowercased() != ".git"
    }

    // MARK: - Materialization

    /// Clones every tracked entry from the clean source checkout into the new worktree.
    ///
    /// Regular files are cloned with `fclonefileat` and never copied: a volume that cannot
    /// clone aborts the fast path so the caller can fall back to an ordinary Git checkout.
    static func materialize(
        entries: [GitWorktreeTrackedTreeEntry],
        sourceRoot: URL,
        destinationRoot: URL,
        destinationRootIdentity: DirectoryIdentity? = nil,
        admittedDirectories: DomainMutationWorktreeDirectories? = nil,
        revalidate: () throws -> Void,
        clone: GitWorktreeFileCloner.CloneSyscall = GitWorktreeFileCloner.systemClone
    ) throws -> GitWorktreeTrackedMaterializationSummary {
        let sourceCursor: GitWorktreeFileCloner.DirectoryCursor
        let destinationCursor: GitWorktreeFileCloner.DirectoryCursor
        if let admittedDirectories {
            try admittedDirectories.revalidate()
            sourceCursor = try GitWorktreeFileCloner.DirectoryCursor(
                rootDescriptor: admittedDirectories.sourceFD,
                createMissing: false
            )
            destinationCursor = try GitWorktreeFileCloner.DirectoryCursor(
                rootDescriptor: admittedDirectories.destinationFD,
                createMissing: true
            )
        } else {
            sourceCursor = try GitWorktreeFileCloner.DirectoryCursor(
                rootPath: sourceRoot.path,
                createMissing: false,
                noFollowRoot: true
            )
            destinationCursor = try GitWorktreeFileCloner.DirectoryCursor(
                rootPath: destinationRoot.path,
                createMissing: true,
                noFollowRoot: true,
                expectedRootIdentity: destinationRootIdentity.map { ($0.device, $0.inode) }
            )
        }
        var summary = GitWorktreeTrackedMaterializationSummary()
        var currentParent: ArraySlice<String>?
        for entry in entries {
            guard let name = entry.pathComponents.last else { continue }
            let parent = entry.pathComponents.dropLast()
            if currentParent != parent {
                try revalidate()
                currentParent = parent
            }
            let sourceDirectory = try sourceCursor.directory(for: parent)
            let destinationDirectory = try destinationCursor.directory(for: parent)
            let outcome = switch entry.kind {
            case .regular, .executable:
                GitWorktreeFileCloner.cloneRegularFile(
                    sourceDirectory: sourceDirectory,
                    name: name,
                    destinationDirectory: destinationDirectory,
                    metadata: .checkoutNormalized(executable: entry.kind == .executable),
                    allowCopyFallback: false,
                    clone: clone,
                    sourceSize: { summary.byteCount += $0 }
                )
            case .symbolicLink:
                GitWorktreeFileCloner.copySymbolicLink(
                    sourceDirectory: sourceDirectory,
                    name: name,
                    destinationDirectory: destinationDirectory
                )
            }
            guard outcome.isMaterialized else {
                throw GitWorktreeTrackedMaterializationError(relativePath: entry.relativePath, outcome: outcome)
            }
            if entry.kind == .symbolicLink {
                summary.symbolicLinkCount += 1
            } else {
                summary.regularFileCount += 1
            }
        }
        return summary
    }
}
