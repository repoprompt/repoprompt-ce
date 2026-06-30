import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

extension FileSystemService {
    struct DirEntry {
        let name: String
        let nameBytes: Data
        let isDir: Bool
        let isSym: Bool
        let fileSystemMode: UInt16

        init(
            name: String,
            nameBytes: Data? = nil,
            isDir: Bool,
            isSym: Bool,
            fileSystemMode: UInt16 = 0
        ) {
            self.name = name
            self.nameBytes = nameBytes ?? Data(name.utf8)
            self.isDir = isDir
            self.isSym = isSym
            self.fileSystemMode = fileSystemMode
        }
    }

    /// Result of scanning a directory including ignore file detection
    struct DirectoryScanResult {
        let entries: [DirEntry]
        let hasGitignore: Bool
        let hasRepoIgnore: Bool
        let hasCursorignore: Bool
    }

    /// A collection of common directory names we *always* skip
    /// in order to avoid scanning huge or irrelevant caches.
    static let universalIgnoreDirs: Set<String> = [
        // Version Control
        ".git", ".svn", ".hg",

        // Node.js / JavaScript
        "node_modules", ".npm", ".pnpm-store", ".yarn", ".cache", "bower_components",

        // Python
        "__pycache__", ".pytest_cache", ".mypy_cache", ".venv", "venv",
        // Some folks also skip .ipynb_checkpoints if using Jupyter

        // Java / JVM
        ".gradle", ".m2", ".idea",

        // .NET / C#
        ".nuget",

        // Rust
        ".cargo", // 'target' is also used by Java, so it's already listed above

        // C/C++
        ".ccache", "gch",

        // Ruby
        ".bundle", ".gem"
    ]

    /// Mark it static so it doesn't require an instance of `self`.
    private static func listDirectory(_ path: String) throws -> [DirEntry] {
        let result = try listDirectoryWithIgnoreDetection(path)
        return result.entries
    }

    #if DEBUG
        /// DEBUG build: use the injected filesystem provider (`fm`) instead of
        /// POSIX `opendir`, so tests can supply virtual files and ignore rules.
        static func listDirectoryWithIgnoreDetection(
            _ path: String,
            fm: any FileSystemProviding
        ) throws -> DirectoryScanResult {
            // If we're running with the real file system, use the same fast
            // POSIX implementation as Release builds so behavior & perf match.
            if fm is FileManager {
                return try listDirectoryWithIgnoreDetection(path) // POSIX version
            }

            // ---------- Unit-test path (virtual FS) ----------
            let dirURL = URL(fileURLWithPath: path)
            let children = try fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )

            var entries: [DirEntry] = []
            var hasGitignore = false
            var hasRepoIgnore = false
            var hasCursorignore = false

            for url in children {
                let name = url.lastPathComponent
                guard name != ".", name != ".." else { continue }
                if Self.isRepoPromptTempFilename(name) { continue }
                switch name {
                case ".gitignore": hasGitignore = true
                case ".repo_ignore": hasRepoIgnore = true
                case ".cursorignore": hasCursorignore = true
                default: break
                }

                var isDirFlag: ObjCBool = false
                _ = fm.fileExists(atPath: url.path, isDirectory: &isDirFlag)

                // Symbolic-link info is best-effort; SpyFS/InMemoryFS will just
                // return `false`, which is fine for tests.
                let isSym = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false

                entries.append(DirEntry(
                    name: name,
                    isDir: isDirFlag.boolValue,
                    isSym: isSym
                ))
            }

            return DirectoryScanResult(
                entries: entries,
                hasGitignore: hasGitignore,
                hasRepoIgnore: hasRepoIgnore,
                hasCursorignore: hasCursorignore
            )
        }
    #endif

    private struct DecodedDirentName {
        let name: String
        let bytes: Data
        let length: Int
    }

    @inline(__always)
    static func isRepoPromptTempFilename(_ name: String) -> Bool {
        name.hasPrefix(".repoprompt.tmp.")
    }

    private static func decodeDirentName(_ entry: dirent) -> DecodedDirentName? {
        withUnsafeBytes(of: entry.d_name) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            let maxCount = buffer.count
            guard maxCount > 0 else { return nil }

            let nameLen = Int(entry.d_namlen)
            var length = 0
            if nameLen > 0 {
                length = min(nameLen, maxCount)
                if length > 0, buffer[length - 1] == 0 {
                    length -= 1
                }
            } else {
                var nulIndex: Int? = nil
                var i = 0
                while i < maxCount {
                    if buffer[i] == 0 {
                        nulIndex = i
                        break
                    }
                    i += 1
                }
                guard let foundIndex = nulIndex else { return nil }
                length = foundIndex
            }

            guard length > 0 else { return nil }

            let bytes = Data(buffer.prefix(length))
            let name = String(decoding: bytes, as: UTF8.self)
            return DecodedDirentName(name: name, bytes: bytes, length: length)
        }
    }

    private static func descriptorRelativeMode(
        dir: UnsafeMutablePointer<DIR>,
        entry: dirent,
        nameLength: Int
    ) -> UInt16 {
        let fd = dirfd(dir)
        guard fd >= 0 else { return 0 }
        var nameBuffer = [CChar](repeating: 0, count: nameLength + 1)
        withUnsafeBytes(of: entry.d_name) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0 ..< min(nameLength, buffer.count) {
                nameBuffer[index] = CChar(bitPattern: buffer[index])
            }
        }
        var status = stat()
        let result = nameBuffer.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return fstatat(fd, base, &status, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 ? UInt16(truncatingIfNeeded: status.st_mode) : 0
    }

    private static func fileTypeFallback(
        dir: UnsafeMutablePointer<DIR>,
        entry: dirent,
        nameLength: Int
    ) -> (isDir: Bool, isSym: Bool) {
        let fd = dirfd(dir)
        guard fd >= 0 else { return (false, false) }

        var nameBuffer = [CChar](repeating: 0, count: nameLength + 1)
        withUnsafeBytes(of: entry.d_name) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            let count = min(nameLength, buffer.count)
            if count > 0 {
                for i in 0 ..< count {
                    nameBuffer[i] = CChar(bitPattern: buffer[i])
                }
            }
        }

        var st = stat()
        let noFollowResult = nameBuffer.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return fstatat(fd, base, &st, AT_SYMLINK_NOFOLLOW)
        }

        guard noFollowResult == 0 else { return (false, false) }
        let noFollowType = st.st_mode & S_IFMT
        let isSym = (noFollowType == S_IFLNK)

        if isSym {
            let followResult = nameBuffer.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return fstatat(fd, base, &st, 0)
            }
            if followResult == 0 {
                let followType = st.st_mode & S_IFMT
                return (followType == S_IFDIR, true)
            }
            return (false, true)
        }

        return (noFollowType == S_IFDIR, false)
    }

    /// Enhanced directory listing that also detects ignore files
    static func listDirectoryWithIgnoreDetection(_ path: String) throws -> DirectoryScanResult {
        // Open the directory
        guard let dir = opendir(path) else {
            throw NSError(
                domain: "listDirectory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open directory: \(path)"]
            )
        }
        defer {
            closedir(dir) // Ensure the directory is closed when done
        }

        var entries = [DirEntry]()
        var hasGitignore = false
        var hasRepoIgnore = false
        var hasCursorignore = false

        // Iterate over directory entries
        while true {
            errno = 0 // Reset errno before each readdir call
            guard let direntPtr = readdir(dir) else {
                if errno != 0 {
                    print("Error reading directory entry for path \(path): \(String(cString: strerror(errno)))")
                }
                break // Exit loop on error or end of directory
            }

            // Safely copy the dirent structure
            let dirent = direntPtr.pointee
            guard let decoded = decodeDirentName(dirent) else {
                continue
            }
            let fileName = decoded.name

            // Skip "." and ".." entries
            if fileName == "." || fileName == ".." {
                continue
            }
            if Self.isRepoPromptTempFilename(fileName) {
                continue
            }
            // Detect ignore files while we're scanning
            if fileName == ".gitignore" {
                hasGitignore = true
            } else if fileName == ".repo_ignore" {
                hasRepoIgnore = true
            } else if fileName == ".cursorignore" {
                hasCursorignore = true
            }

            // Determine file type from d_type
            let dType = dirent.d_type
            var isDir = false
            var isSym = false

            switch Int32(dType) {
            case DT_DIR:
                isDir = true
            case DT_LNK:
                let fallback = fileTypeFallback(
                    dir: dir,
                    entry: dirent,
                    nameLength: decoded.length
                )
                isDir = fallback.isDir
                isSym = true
            case DT_UNKNOWN:
                let fallback = fileTypeFallback(
                    dir: dir,
                    entry: dirent,
                    nameLength: decoded.length
                )
                isDir = fallback.isDir
                isSym = fallback.isSym
            default:
                break // Regular files and other types don't set isDir or isSym
            }

            // Add the entry to the results
            entries.append(DirEntry(
                name: fileName,
                nameBytes: decoded.bytes,
                isDir: isDir,
                isSym: isSym,
                fileSystemMode: descriptorRelativeMode(
                    dir: dir,
                    entry: dirent,
                    nameLength: decoded.length
                )
            ))
        }

        return DirectoryScanResult(
            entries: entries,
            hasGitignore: hasGitignore,
            hasRepoIgnore: hasRepoIgnore,
            hasCursorignore: hasCursorignore
        )
    }

    /// Reads a directory using `scandir(3)`, skipping "." and "..".
    /// Mark it static so it doesn't require an instance of `self`.
    private static func scandirListDirectory(_ path: String) throws -> [DirEntry] {
        var namelist: UnsafeMutablePointer<UnsafeMutablePointer<dirent>?>? = nil

        let count = scandir(path, &namelist, nil, nil)
        guard count >= 0 else {
            throw NSError(
                domain: "scandirListDirectory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open directory: \(path)"]
            )
        }
        defer {
            // Free the memory allocated by scandir
            for i in 0 ..< count {
                free(namelist![Int(i)])
            }
            free(namelist)
        }

        var entries = [DirEntry]()
        entries.reserveCapacity(Int(count))

        for i in 0 ..< count {
            // Copy dirent into local var so the pointer remains valid for the entire iteration
            let localDirent = namelist![Int(i)]!.pointee

            // Safely convert d_name -> Swift String
            guard let decoded = decodeDirentName(localDirent) else {
                continue
            }
            let rawName = decoded.name

            // Skip "." and ".."
            guard rawName != ".", rawName != ".." else {
                continue
            }
            if Self.isRepoPromptTempFilename(rawName) {
                continue
            }

            let dType = localDirent.d_type // This is a UInt8
            var isDir = false
            var isSym = false

            switch Int32(dType) {
            case DT_DIR:
                isDir = true
            case DT_LNK:
                isSym = true
                let fullPath = (path as NSString).appendingPathComponent(rawName)
                var st = stat()
                if stat(fullPath, &st) == 0,
                   (st.st_mode & S_IFMT) == S_IFDIR
                {
                    isDir = true
                }
            case DT_UNKNOWN:
                // If d_type is unknown, do a stat() fallback
                let fullPath = (path as NSString).appendingPathComponent(rawName)
                var st = stat()
                if stat(fullPath, &st) == 0,
                   (st.st_mode & S_IFMT) == S_IFDIR
                {
                    isDir = true
                }
            default:
                // e.g. DT_REG (regular file), DT_FIFO, DT_CHR, etc.
                break
            }

            // Finally, record the entry
            entries.append(DirEntry(
                name: rawName,
                nameBytes: decoded.bytes,
                isDir: isDir,
                isSym: isSym
            ))
        }

        return entries
    }

    /// Physical directory identity (stable for cycle checks).
    struct DirID: Hashable {
        let dev: UInt64
        let ino: UInt64
    }

    /// `stat()` follows symlinks → this returns the target directory identity.
    @inline(__always)
    static func dirID(followingSymlinksAtPath path: String) -> DirID? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return DirID(dev: UInt64(st.st_dev), ino: UInt64(st.st_ino))
    }

    /// Canonicalize a path via `realpath()`. Returns nil on ELOOP, missing targets, etc.
    @inline(__always)
    static func realpathString(_ path: String) -> String? {
        path.withCString { cPath in
            guard let resolved = realpath(cPath, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
