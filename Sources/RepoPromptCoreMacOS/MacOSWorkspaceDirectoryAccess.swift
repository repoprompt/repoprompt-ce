import Darwin
import Foundation
import RepoPromptCore

package struct MacOSWorkspaceDirectoryAccess: WorkspaceDirectoryAccessing {
    package init() {}

    package func listDirectoryWithIgnoreDetection(
        at path: String
    ) throws -> WorkspaceDirectoryScanResult {
        guard let directory = opendir(path) else {
            throw NSError(
                domain: "listDirectory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open directory: \(path)"]
            )
        }
        defer { closedir(directory) }

        var entries: [WorkspaceDirectoryEntry] = []
        var hasGitignore = false
        var hasRepoIgnore = false
        var hasCursorignore = false

        while true {
            errno = 0
            guard let pointer = readdir(directory) else {
                break
            }
            let entry = pointer.pointee
            guard let decoded = decodeName(entry),
                  decoded.name != ".",
                  decoded.name != "..",
                  !decoded.name.hasPrefix(".repoprompt.tmp.")
            else { continue }

            switch decoded.name {
            case ".gitignore": hasGitignore = true
            case ".repo_ignore": hasRepoIgnore = true
            case ".cursorignore": hasCursorignore = true
            default: break
            }

            entries.append(
                WorkspaceDirectoryEntry(
                    name: decoded.name,
                    kind: fileKind(
                        directory: directory,
                        entry: entry,
                        nameLength: decoded.length
                    )
                )
            )
        }

        return WorkspaceDirectoryScanResult(
            entries: entries,
            hasGitignore: hasGitignore,
            hasRepoIgnore: hasRepoIgnore,
            hasCursorignore: hasCursorignore
        )
    }

    package func directoryIdentity(
        followingSymlinksAt path: String
    ) -> WorkspaceDirectoryIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return WorkspaceDirectoryIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    package func canonicalPath(for path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private struct DecodedName {
        let name: String
        let length: Int
    }

    private func decodeName(_ entry: dirent) -> DecodedName? {
        withUnsafeBytes(of: entry.d_name) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            guard !buffer.isEmpty else { return nil }
            var length = Int(entry.d_namlen)
            if length > 0 {
                length = min(length, buffer.count)
                if buffer[length - 1] == 0 { length -= 1 }
            } else {
                guard let nul = buffer.firstIndex(of: 0) else { return nil }
                length = nul
            }
            guard length > 0 else { return nil }
            return DecodedName(
                name: String(decoding: buffer.prefix(length), as: UTF8.self),
                length: length
            )
        }
    }

    private func fileKind(
        directory: UnsafeMutablePointer<DIR>,
        entry: dirent,
        nameLength: Int
    ) -> WorkspaceDirectoryEntry.Kind {
        switch Int32(entry.d_type) {
        case DT_DIR:
            .directory
        case DT_LNK, DT_UNKNOWN:
            fallbackFileKind(
                directory: directory,
                entry: entry,
                nameLength: nameLength
            )
        case DT_REG:
            .regularFile
        default:
            .other
        }
    }

    private func fallbackFileKind(
        directory: UnsafeMutablePointer<DIR>,
        entry: dirent,
        nameLength: Int
    ) -> WorkspaceDirectoryEntry.Kind {
        let descriptor = dirfd(directory)
        guard descriptor >= 0 else { return .other }
        var name = [CChar](repeating: 0, count: nameLength + 1)
        withUnsafeBytes(of: entry.d_name) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0 ..< min(nameLength, bytes.count) {
                name[index] = CChar(bitPattern: bytes[index])
            }
        }

        var info = stat()
        let noFollow = name.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Int32(-1) }
            return fstatat(descriptor, base, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard noFollow == 0 else { return .other }

        let isSymbolicLink = (info.st_mode & S_IFMT) == S_IFLNK
        if isSymbolicLink {
            let follow = name.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return Int32(-1) }
                return fstatat(descriptor, base, &info, 0)
            }
            return .symbolicLink(
                isDirectory: follow == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            )
        }
        if (info.st_mode & S_IFMT) == S_IFDIR { return .directory }
        if (info.st_mode & S_IFMT) == S_IFREG { return .regularFile }
        return .other
    }
}
