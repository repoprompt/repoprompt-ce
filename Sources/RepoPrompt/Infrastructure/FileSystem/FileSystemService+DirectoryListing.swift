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
        let nullTerminatedName: [CChar]
        let dType: UInt8
    }

    private struct DirentRecordLayout {
        let recordLengthOffset: Int
        let nameLengthOffset: Int
        let typeOffset: Int
        let nameOffset: Int
        let nameCapacity: Int
        let minimumRecordLength: Int
        let fullStructSize: Int

        static let current: Self = {
            let recordLengthOffset = MemoryLayout<dirent>.offset(of: \dirent.d_reclen)!
            let nameLengthOffset = MemoryLayout<dirent>.offset(of: \dirent.d_namlen)!
            let typeOffset = MemoryLayout<dirent>.offset(of: \dirent.d_type)!
            let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
            let nameCapacity = MemoryLayout.size(ofValue: dirent().d_name)
            let scalarFieldsEnd = max(
                recordLengthOffset + MemoryLayout<UInt16>.size,
                nameLengthOffset + MemoryLayout<UInt16>.size,
                typeOffset + MemoryLayout<UInt8>.size
            )
            return Self(
                recordLengthOffset: recordLengthOffset,
                nameLengthOffset: nameLengthOffset,
                typeOffset: typeOffset,
                nameOffset: nameOffset,
                nameCapacity: nameCapacity,
                minimumRecordLength: max(scalarFieldsEnd, nameOffset + 1),
                fullStructSize: MemoryLayout<dirent>.size
            )
        }()
    }

    #if DEBUG
        struct DirentRecordLayoutForTesting {
            let recordLengthOffset: Int
            let nameLengthOffset: Int
            let typeOffset: Int
            let nameOffset: Int
            let nameCapacity: Int
            let minimumRecordLength: Int
            let fullStructSize: Int
        }

        static var direntRecordLayoutForTesting: DirentRecordLayoutForTesting {
            let layout = DirentRecordLayout.current
            return DirentRecordLayoutForTesting(
                recordLengthOffset: layout.recordLengthOffset,
                nameLengthOffset: layout.nameLengthOffset,
                typeOffset: layout.typeOffset,
                nameOffset: layout.nameOffset,
                nameCapacity: layout.nameCapacity,
                minimumRecordLength: layout.minimumRecordLength,
                fullStructSize: layout.fullStructSize
            )
        }

        static func decodeDirentRecordForTesting(_ bytes: [UInt8]) -> (name: String, bytes: Data, dType: UInt8)? {
            bytes.withUnsafeBytes { record in
                guard let decoded = decodeDirentRecord(record) else { return nil }
                return (decoded.name, decoded.bytes, decoded.dType)
            }
        }

        static func decodeDirentPointerForTesting(
            _ entryPtr: UnsafePointer<dirent>
        ) -> (name: String, bytes: Data, dType: UInt8)? {
            guard let decoded = decodeDirentName(entryPtr) else { return nil }
            return (decoded.name, decoded.bytes, decoded.dType)
        }
    #endif

    @inline(__always)
    static func isRepoPromptTempFilename(_ name: String) -> Bool {
        name.hasPrefix(".repoprompt.tmp.")
    }

    /// Decodes only the variable-length record returned by `readdir`/`scandir`.
    /// Reading `entryPtr.pointee` would copy the full imported `dirent`, even when
    /// the OS-owned record ends much earlier in the directory buffer.
    private static func decodeDirentName(_ entryPtr: UnsafePointer<dirent>) -> DecodedDirentName? {
        let layout = DirentRecordLayout.current
        let rawPointer = UnsafeRawPointer(entryPtr)
        let recordLength = Int(rawPointer.loadUnaligned(
            fromByteOffset: layout.recordLengthOffset,
            as: UInt16.self
        ))
        guard recordLength >= layout.minimumRecordLength,
              recordLength <= layout.fullStructSize
        else {
            return nil
        }

        return decodeDirentRecord(UnsafeRawBufferPointer(start: rawPointer, count: recordLength))
    }

    private static func decodeDirentRecord(_ record: UnsafeRawBufferPointer) -> DecodedDirentName? {
        let layout = DirentRecordLayout.current
        guard record.count >= layout.minimumRecordLength,
              record.count <= layout.fullStructSize,
              Int(record.loadUnaligned(
                  fromByteOffset: layout.recordLengthOffset,
                  as: UInt16.self
              )) == record.count
        else {
            return nil
        }

        let availableNameBytes = min(record.count - layout.nameOffset, layout.nameCapacity)
        let declaredNameLength = Int(record.loadUnaligned(
            fromByteOffset: layout.nameLengthOffset,
            as: UInt16.self
        ))
        let length: Int
        if declaredNameLength > 0 {
            guard declaredNameLength < availableNameBytes,
                  record[layout.nameOffset + declaredNameLength] == 0
            else {
                return nil
            }
            length = declaredNameLength
        } else {
            var nulIndex: Int?
            for index in 0 ..< availableNameBytes where record[layout.nameOffset + index] == 0 {
                nulIndex = index
                break
            }
            guard let nulIndex else { return nil }
            length = nulIndex
        }
        guard length > 0, let recordBaseAddress = record.baseAddress else { return nil }

        let namePointer = recordBaseAddress.advanced(by: layout.nameOffset)
        let bytes = Data(bytes: namePointer, count: length)
        var nullTerminatedName = bytes.map { CChar(bitPattern: $0) }
        nullTerminatedName.append(0)
        return DecodedDirentName(
            name: String(decoding: bytes, as: UTF8.self),
            bytes: bytes,
            nullTerminatedName: nullTerminatedName,
            dType: record.loadUnaligned(fromByteOffset: layout.typeOffset, as: UInt8.self)
        )
    }

    private static func descriptorRelativeMode(
        dir: UnsafeMutablePointer<DIR>,
        name: [CChar]
    ) -> UInt16 {
        let fd = dirfd(dir)
        guard fd >= 0 else { return 0 }
        var status = stat()
        let result = name.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return fstatat(fd, base, &status, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 ? UInt16(truncatingIfNeeded: status.st_mode) : 0
    }

    private static func fileTypeFallback(
        dir: UnsafeMutablePointer<DIR>,
        name: [CChar]
    ) -> (isDir: Bool, isSym: Bool) {
        let fd = dirfd(dir)
        guard fd >= 0 else { return (false, false) }

        var st = stat()
        let noFollowResult = name.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return fstatat(fd, base, &st, AT_SYMLINK_NOFOLLOW)
        }

        guard noFollowResult == 0 else { return (false, false) }
        let noFollowType = st.st_mode & S_IFMT
        let isSym = (noFollowType == S_IFLNK)

        if isSym {
            let followResult = name.withUnsafeBufferPointer { buffer -> Int32 in
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

            // Decode and copy the needed bytes before the next readdir call invalidates the record.
            guard let decoded = decodeDirentName(direntPtr) else {
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

            // d_type was decoded without a full struct copy
            let dType = decoded.dType
            var isDir = false
            var isSym = false

            switch Int32(dType) {
            case DT_DIR:
                isDir = true
            case DT_LNK:
                let fallback = fileTypeFallback(
                    dir: dir,
                    name: decoded.nullTerminatedName
                )
                isDir = fallback.isDir
                isSym = true
            case DT_UNKNOWN:
                let fallback = fileTypeFallback(
                    dir: dir,
                    name: decoded.nullTerminatedName
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
                    name: decoded.nullTerminatedName
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
            // Each scandir record remains owned by this loop until the deferred free.
            let entryPtr = namelist![Int(i)]!

            // Safely convert d_name -> Swift String
            guard let decoded = decodeDirentName(entryPtr) else {
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

            let dType = decoded.dType
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
