import Foundation

extension FileSystemService {
    // MARK: - Helpers

    package func fullPath(forRelativePath relativePath: String) -> String {
        let sanitized: String
        if relativePath.hasPrefix("/") {
            let trimmed = relativePath.drop { $0 == "/" }
            sanitized = String(trimmed)
        } else {
            sanitized = relativePath
        }
        return (path as NSString).appendingPathComponent(sanitized)
    }

    enum RelativeEventPath {
        case inside(relative: String)
        case outside(originalAbsolute: String)
    }

    func fileOrFolderIsDir(_ relativePath: String) -> Bool {
        let full = (path as NSString).appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: full, isDirectory: &isDir)
        return isDir.boolValue
    }

    @inline(__always)
    nonisolated static func trimPathSlashes(_ value: some StringProtocol) -> String {
        var start = value.startIndex
        var end = value.endIndex
        while start < end, value[start] == "/" {
            start = value.index(after: start)
        }
        while end > start {
            let previous = value.index(before: end)
            guard value[previous] == "/" else { break }
            end = previous
        }
        return String(value[start ..< end])
    }

    @inline(__always)
    func mapToRelativeEventPath(_ absolutePath: String) -> RelativeEventPath {
        guard Self.eventPathIsSafeForRawPrefixMapping(absolutePath) else {
            return mapToRelativeEventPathFallback(absolutePath)
        }
        if hasDirectoryPrefix(absolutePath, standardizedRootPath) {
            let rel = absolutePath.dropFirst(standardizedRootPath.count)
            return .inside(relative: Self.trimPathSlashes(rel))
        }
        if canonicalRootPath != standardizedRootPath,
           hasDirectoryPrefix(absolutePath, canonicalRootPath)
        {
            let rel = absolutePath.dropFirst(canonicalRootPath.count)
            return .inside(relative: Self.trimPathSlashes(rel))
        }
        return mapToRelativeEventPathFallback(absolutePath)
    }

    func mapToRelativeEventPathFallback(_ absolutePath: String) -> RelativeEventPath {
        guard !absolutePath.isEmpty else {
            return .outside(originalAbsolute: absolutePath)
        }

        let standardizedAbsolute = NSString(string: absolutePath).standardizingPath
        if hasDirectoryPrefix(standardizedAbsolute, standardizedRootPath) {
            let rel = standardizedAbsolute.dropFirst(standardizedRootPath.count)
            return .inside(relative: Self.trimPathSlashes(rel))
        }

        let canonicalAbsolute = URL(fileURLWithPath: standardizedAbsolute).resolvingSymlinksInPath().path
        if hasDirectoryPrefix(canonicalAbsolute, canonicalRootPath) {
            let rel = canonicalAbsolute.dropFirst(canonicalRootPath.count)
            return .inside(relative: Self.trimPathSlashes(rel))
        }

        return .outside(originalAbsolute: standardizedAbsolute)
    }

    @inline(__always)
    nonisolated static func eventPathIsSafeForRawPrefixMapping(_ path: String) -> Bool {
        var byteCount = 0
        var previousWasSlash = false
        var currentComponentLength = 0
        var currentComponentDotCount = 0
        var currentComponentOnlyDots = true

        for byte in path.utf8 {
            if byteCount == 0 {
                guard byte == 47 else { return false }
                previousWasSlash = true
                byteCount += 1
                continue
            }

            if byte == 0 { return false }
            if byte == 47 {
                if previousWasSlash { return false }
                if currentComponentOnlyDots, currentComponentDotCount == 1 || currentComponentDotCount == 2 {
                    return false
                }
                previousWasSlash = true
                currentComponentLength = 0
                currentComponentDotCount = 0
                currentComponentOnlyDots = true
            } else {
                previousWasSlash = false
                currentComponentLength += 1
                if currentComponentOnlyDots, byte == 46 {
                    currentComponentDotCount += 1
                } else {
                    currentComponentOnlyDots = false
                }
            }
            byteCount += 1
        }

        guard byteCount > 0 else { return false }
        if previousWasSlash {
            return byteCount == 1
        }
        if currentComponentLength > 0,
           currentComponentOnlyDots,
           currentComponentDotCount == 1 || currentComponentDotCount == 2
        {
            return false
        }
        return true
    }

    @inline(__always)
    func hasDirectoryPrefix(_ path: String, _ base: String) -> Bool {
        guard path.hasPrefix(base) else { return false }
        if path.count == base.count { return true }
        let idx = path.index(path.startIndex, offsetBy: base.count)
        return path[idx] == "/"
    }

    func relativePathFor(_ absolutePath: String) -> String {
        switch mapToRelativeEventPath(absolutePath) {
        case let .inside(relative):
            relative
        case let .outside(original):
            original
        }
    }

    func parentDirectory(of relativePath: String) -> String {
        guard let slashIndex = relativePath.lastIndex(of: "/") else {
            return ""
        }
        return String(relativePath[..<slashIndex])
    }

    func isSpecialControlFile(_ relPath: String) -> Bool {
        isIgnoreFile(relPath)
    }

    func isIgnoreFile(_ relPath: String) -> Bool {
        let filename = (relPath as NSString).lastPathComponent.lowercased()
        return filename == ".gitignore" || filename == ".repo_ignore" || filename == ".cursorignore"
    }

    @inline(__always)
    func isRepoPromptTempPath(_ relPath: String) -> Bool {
        if relPath.hasPrefix(".repoprompt.tmp.") { return true }
        return relPath.contains("/.repoprompt.tmp.")
    }

    func isGitMetadataPath(_ relPath: String) -> Bool {
        if relPath.isEmpty { return false }
        if relPath == ".git" { return true }
        return relPath.hasPrefix(".git/")
    }

    /// Static version so off-actor code can do the same boundary check.
    @inline(__always)
    static func hasDirectoryPrefix(_ path: String, _ base: String) -> Bool {
        guard path.hasPrefix(base) else { return false }
        if path.count == base.count { return true }
        let idx = path.index(path.startIndex, offsetBy: base.count)
        return path[idx] == "/"
    }
}

// MARK: - FileManager extension

extension FileManager {
    func isFolder(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}

// MARK: - URL extension

package extension URL {
    func relativePath(from base: URL) -> String {
        let basePath = (base.path as NSString).standardizingPath
        let filePath = (path as NSString).standardizingPath

        if filePath == basePath { return "" }

        let prefix: String = if basePath == "/" {
            "/"
        } else if basePath.hasSuffix("/") {
            basePath
        } else {
            basePath + "/"
        }

        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return filePath
    }
}
