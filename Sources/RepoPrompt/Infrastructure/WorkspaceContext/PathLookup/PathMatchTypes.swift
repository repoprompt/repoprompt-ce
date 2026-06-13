import Foundation

// MARK: - Path Match Result Types

/// Pure-value result coming from the background PathMatcher.
/// No actor references – therefore `Sendable` by default.
struct PathMatchLocation {
    let rootPath: String // absolute path of the owning repo root
    let correctedPath: String // final relative path inside that root
}

// MARK: - Immutable Snapshot Types

struct PathMatchCacheIdentity: Hashable {
    let scopeID: UInt64
    let snapshotID: UInt64
}

/// Static part of the snapshot (expensive to build, cached).
/// Immutable, cross-actor-safe snapshot used by PathMatcher and PathMatchWorker.
/// All references to UI/ViewModel types are stripped; uses frozen records only.
struct StaticPathMatchData {
    let filesByFullPath: [String: FileRecord]
    let foldersByFullPath: [String: FolderRecord]
    let rootFolders: [FolderRecord]

    // Case-insensitive dictionaries (no duplicates in original maps)
    let filesByLowerFullPath: [String: FileRecord]
    let foldersByLowerFullPath: [String: FolderRecord]

    /// Matching policy - current default is case-insensitive
    let caseSensitive: Bool

    /// Scope plus snapshot identity used to retain unaffected cached path indexes.
    let cacheIdentity: PathMatchCacheIdentity

    /// Monotonic id to allow callers to compare snapshot generations.
    let id: UInt64

    init(
        filesByFullPath: [String: FileRecord],
        foldersByFullPath: [String: FolderRecord],
        rootFolders: [FolderRecord],
        cacheScopeID: UInt64 = 0,
        id: UInt64,
        caseSensitive: Bool = false
    ) {
        self.filesByFullPath = filesByFullPath
        self.foldersByFullPath = foldersByFullPath
        self.rootFolders = rootFolders
        cacheIdentity = PathMatchCacheIdentity(scopeID: cacheScopeID, snapshotID: id)
        self.id = id

        // Handle potential case-insensitive collisions by keeping the first occurrence
        var filesByLower: [String: FileRecord] = [:]
        for (path, record) in filesByFullPath {
            let lowerPath = path.lowercased()
            if filesByLower[lowerPath] == nil {
                filesByLower[lowerPath] = record
            }
        }
        filesByLowerFullPath = filesByLower

        var foldersByLower: [String: FolderRecord] = [:]
        for (path, record) in foldersByFullPath {
            let lowerPath = path.lowercased()
            if foldersByLower[lowerPath] == nil {
                foldersByLower[lowerPath] = record
            }
        }
        foldersByLowerFullPath = foldersByLower

        self.caseSensitive = caseSensitive
    }
}

/// Immutable snapshot of file hierarchy state for path matching.
/// All references to UI/ViewModel types are stripped; uses frozen records only.
struct PathMatchSnapshot {
    let filesByFullPath: [String: FileRecord]
    let foldersByFullPath: [String: FolderRecord]
    let rootFolders: [FolderRecord]

    // Case-insensitive dictionaries copied from StaticPathMatchData or computed on the fly
    let filesByLowerFullPath: [String: FileRecord]
    let foldersByLowerFullPath: [String: FolderRecord]

    let selectedFileFullPaths: Set<String>

    /// Fully computed indexes – no internal locking, built on the worker actor.
    private let storedIndexes: PathMatchIndexes
    var indexes: PathMatchIndexes {
        storedIndexes
    }

    /// Matching policy flag (current default is case-insensitive)
    let caseSensitive: Bool

    /// Primary initializer used by PathMatchWorker.
    /// Accepts pre-computed indexes from the worker's cache.
    init(
        staticData: StaticPathMatchData,
        selectedFileFullPaths: Set<String>,
        indexes: PathMatchIndexes
    ) {
        filesByFullPath = staticData.filesByFullPath
        foldersByFullPath = staticData.foldersByFullPath
        rootFolders = staticData.rootFolders
        filesByLowerFullPath = staticData.filesByLowerFullPath
        foldersByLowerFullPath = staticData.foldersByLowerFullPath
        self.selectedFileFullPaths = selectedFileFullPaths
        storedIndexes = indexes
        caseSensitive = staticData.caseSensitive
    }

    /// Convenience initializer for tests and legacy code.
    /// Builds indexes synchronously (expensive for large file trees).
    init(
        filesByFullPath: [String: FileRecord],
        foldersByFullPath: [String: FolderRecord],
        rootFolders: [FolderRecord],
        selectedFileFullPaths: Set<String> = []
    ) {
        var normalizedFilesByFullPath: [String: FileRecord] = [:]
        normalizedFilesByFullPath.reserveCapacity(filesByFullPath.count)
        for (path, rec) in filesByFullPath {
            let standardizedPath = StandardizedPath.absolute(path)
            let standardizedRootPath = StandardizedPath.absolute(rec.rootFolderPath)
            guard normalizedFilesByFullPath[standardizedPath] == nil else { continue }
            normalizedFilesByFullPath[standardizedPath] = FrozenFileRecord(
                name: rec.name,
                relativePath: RelativePath.fromStandardized(
                    standardizedAbsolutePath: standardizedPath,
                    standardizedRootPath: standardizedRootPath
                ),
                fullPath: standardizedPath,
                rootFolderPath: standardizedRootPath
            )
        }

        var normalizedFoldersByFullPath: [String: FolderRecord] = [:]
        normalizedFoldersByFullPath.reserveCapacity(foldersByFullPath.count)
        for (path, rec) in foldersByFullPath {
            let standardizedPath = StandardizedPath.absolute(path)
            let standardizedRootPath = StandardizedPath.absolute(rec.rootPath)
            guard normalizedFoldersByFullPath[standardizedPath] == nil else { continue }
            normalizedFoldersByFullPath[standardizedPath] = FrozenFolderRecord(
                name: rec.name,
                relativePath: RelativePath.fromStandardized(
                    standardizedAbsolutePath: standardizedPath,
                    standardizedRootPath: standardizedRootPath
                ),
                fullPath: standardizedPath,
                rootPath: standardizedRootPath,
                displayName: rec.displayName
            )
        }

        var normalizedRootFolders: [FolderRecord] = []
        normalizedRootFolders.reserveCapacity(rootFolders.count)
        var seenRootPaths = Set<String>()
        for root in rootFolders {
            let standardizedRootPath = StandardizedPath.absolute(root.fullPath)
            let standardizedParentRootPath = StandardizedPath.absolute(root.rootPath)
            guard seenRootPaths.insert(standardizedRootPath).inserted else { continue }
            normalizedRootFolders.append(
                FrozenFolderRecord(
                    name: root.name,
                    relativePath: RelativePath.fromStandardized(
                        standardizedAbsolutePath: standardizedRootPath,
                        standardizedRootPath: standardizedParentRootPath
                    ),
                    fullPath: standardizedRootPath,
                    rootPath: standardizedParentRootPath,
                    displayName: root.displayName
                )
            )
        }

        self.filesByFullPath = normalizedFilesByFullPath
        self.foldersByFullPath = normalizedFoldersByFullPath
        self.rootFolders = normalizedRootFolders

        // Duplicate-safe "first wins" build to avoid traps on case-sensitive filesystems
        var filesLower: [String: FileRecord] = [:]
        for (path, rec) in normalizedFilesByFullPath {
            let lower = path.lowercased()
            if filesLower[lower] == nil {
                filesLower[lower] = rec
            }
        }
        filesByLowerFullPath = filesLower

        var foldersLower: [String: FolderRecord] = [:]
        for (path, rec) in normalizedFoldersByFullPath {
            let lower = path.lowercased()
            if foldersLower[lower] == nil {
                foldersLower[lower] = rec
            }
        }
        foldersByLowerFullPath = foldersLower
        self.selectedFileFullPaths = Set(selectedFileFullPaths.map(StandardizedPath.absolute))

        // Default policy: case-insensitive
        let policyCaseSensitive = false
        caseSensitive = policyCaseSensitive

        // Build indexes synchronously (tests / legacy path)
        storedIndexes = PathMatchIndexes.build(
            files: normalizedFilesByFullPath,
            folders: normalizedFoldersByFullPath,
            caseSensitive: policyCaseSensitive
        )
    }

    // MARK: − Convenience helpers

    func fileRecord(forFullPath path: String) -> FileRecord? {
        let std = (path as NSString).standardizingPath
        return fileRecord(forStandardizedFullPath: std)
    }

    func fileRecord(forStandardizedFullPath path: String) -> FileRecord? {
        filesByFullPath[path] ?? filesByLowerFullPath[path.lowercased()]
    }

    func folderRecord(forFullPath path: String) -> FolderRecord? {
        let std = (path as NSString).standardizingPath
        return folderRecord(forStandardizedFullPath: std)
    }

    func folderRecord(forStandardizedFullPath path: String) -> FolderRecord? {
        foldersByFullPath[path] ?? foldersByLowerFullPath[path.lowercased()]
    }
}

extension PathMatchSnapshot {
    func canonical(_ s: String) -> String {
        PathMatchIndexes.canonical(s, caseSensitive: caseSensitive)
    }
}

struct PathMatchIndexes {
    let byFileName: [String: [FileRecord]]
    let byLastTwo: [String: [FileRecord]]
    let byExtension: [String: [FileRecord]]
    let foldersByLastComponent: [String: [FolderRecord]]

    static func canonical(_ s: String, caseSensitive: Bool) -> String {
        // Quick ASCII probe: if all bytes < 0x80, skip folding entirely
        var isASCII = true
        for b in s.utf8 {
            if b >= 0x80 { isASCII = false
                break
            }
        }
        let input = isASCII ? s : PathCharPolicy.foldHomoglyphsIfNeeded(s)
        // Fast path: ASCII-only scan using UTF-8 bytes; avoid CharacterSet/CF calls entirely
        var sawNonASCII = false
        var out = [UInt8]()
        out.reserveCapacity(input.utf8.count)

        for b in input.utf8 {
            if b < 0x80 {
                if PathCharPolicy.isAllowedASCIIByte(b) {
                    out.append(caseSensitive ? b : PathCharPolicy.toLowerASCII(b))
                }
            } else {
                sawNonASCII = true
            }
        }

        if !sawNonASCII {
            // ASCII-only: already filtered & case-normalized (if requested)
            return String(decoding: out, as: UTF8.self)
        }

        // Slow path: Unicode scalars (rare); keep alphanumerics + our ASCII punctuation
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(input.unicodeScalars.count)
        for sc in input.unicodeScalars {
            // After pre-folding, we can append as-is in the fallback
            if sc.value < 0x80 {
                if PathCharPolicy.isAllowedASCIIByte(UInt8(truncatingIfNeeded: sc.value)) {
                    scalars.append(sc)
                }
            } else if CharacterSet.alphanumerics.contains(sc) {
                scalars.append(sc)
            }
        }
        let filtered = String(scalars)
        return caseSensitive ? filtered : filtered.lowercased()
    }

    static func build(
        files: [String: FileRecord],
        folders: [String: FolderRecord],
        caseSensitive: Bool
    ) -> PathMatchIndexes {
        var byFileName: [String: [FileRecord]] = [:]
        var byLastTwo: [String: [FileRecord]] = [:]
        var byExtension: [String: [FileRecord]] = [:]
        var foldersByLastComponent: [String: [FolderRecord]] = [:]

        // Files
        for (_, file) in files {
            let nameKey = canonical(file.name, caseSensitive: caseSensitive)
            byFileName[nameKey, default: []].append(file)

            let ext = (file.name as NSString).pathExtension.lowercased()
            if !ext.isEmpty {
                byExtension[ext, default: []].append(file)
            }

            let comps = file.relativePath.split(separator: "/").map(String.init)
            if comps.count >= 2 {
                let lastTwo = comps[comps.count - 2] + "/" + comps[comps.count - 1]
                let key2 = canonical(lastTwo, caseSensitive: caseSensitive)
                byLastTwo[key2, default: []].append(file)
            }
        }

        // Folders
        for (_, folder) in folders {
            let lastKey = canonical(folder.name, caseSensitive: caseSensitive)
            foldersByLastComponent[lastKey, default: []].append(folder)
        }

        return PathMatchIndexes(
            byFileName: byFileName,
            byLastTwo: byLastTwo,
            byExtension: byExtension,
            foldersByLastComponent: foldersByLastComponent
        )
    }
}

enum PathLocateProfile: Hashable {
    case uiAssisted
    case mcpRead
    case mcpSelection
    case mcpSearchScope
    case moveSourceExact
    case createBestEffort
    case createRequireUnambiguous

    var options: PathLocateOptions {
        switch self {
        case .uiAssisted:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: true,
                useSelectedRootBias: true
            )
        case .mcpRead, .mcpSelection, .mcpSearchScope:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: true,
                useSelectedRootBias: false
            )
        case .moveSourceExact:
            PathLocateOptions(
                exactMatchOnly: true,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: false,
                allowAbsoluteSuffixFallback: false,
                useSelectedRootBias: false
            )
        case .createBestEffort:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: false,
                useSelectedRootBias: true
            )
        case .createRequireUnambiguous:
            PathLocateOptions(
                exactMatchOnly: false,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: false,
                useSelectedRootBias: false
            )
        }
    }
}

struct PathLocateOptions: Equatable {
    let exactMatchOnly: Bool
    let allowLeadingRootAliasTrim: Bool
    let allowHeadTrimAliases: Bool
    let allowAbsoluteSuffixFallback: Bool
    let useSelectedRootBias: Bool
}

/// Result of finding a path for file creation
struct FileCreationResult {
    let rootFolder: FolderRecord
    let componentsToCreate: [String]
}

extension FileCreationResult: Equatable {
    static func == (lhs: FileCreationResult, rhs: FileCreationResult) -> Bool {
        lhs.rootFolder.fullPath == rhs.rootFolder.fullPath &&
            lhs.componentsToCreate == rhs.componentsToCreate
    }
}

/// Controls how `resolveCreationPath` handles ties between candidate roots.
enum CreationResolutionMode {
    /// Best-effort heuristic tie-breaking (current behavior): always returns a single winner.
    case bestEffort
    /// Report ambiguity: if multiple roots tie on structural signals, return `.ambiguous`.
    case requireUnambiguous
}

/// Result of path resolution for file creation with ambiguity detection.
enum FileCreationResolution: Equatable {
    /// Unambiguous resolution to a single root.
    case unique(FileCreationResult)
    /// Multiple roots are equally valid candidates; caller should request disambiguation.
    case ambiguous(candidateRootPaths: [String])
}

/// Helper enum for handling heterogeneous file/folder collections
enum AnyItem {
    case folder(FolderRecord)
    case file(FileRecord)

    var name: String {
        switch self {
        case let .folder(f): f.name
        case let .file(f): f.name
        }
    }

    var rootPath: String {
        switch self {
        case let .folder(f): f.rootPath
        case let .file(f): f.rootFolderPath
        }
    }

    var relativePath: String {
        switch self {
        case let .folder(f): f.relativePath
        case let .file(f): f.relativePath
        }
    }
}
