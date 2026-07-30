import Foundation

/// Pure string-based relative path computation (no filesystem I/O).
enum RelativePath {
    @inline(__always)
    static func from(absolutePath: String, rootPath: String) -> String {
        let abs = (absolutePath as NSString).standardizingPath
        let root = (rootPath as NSString).standardizingPath
        return fromStandardized(standardizedAbsolutePath: abs, standardizedRootPath: root)
    }

    @inline(__always)
    static func fromStandardized(
        standardizedAbsolutePath abs: String,
        standardizedRootPath root: String
    ) -> String {
        guard !root.isEmpty else { return abs }
        if abs == root {
            return ""
        }

        // Boundary-safe prefix match (prevents "/a/bc" being treated as inside "/a/b").
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        if abs.hasPrefix(rootPrefix) {
            return String(abs.dropFirst(rootPrefix.count))
        }
        // Outside root -> match previous behavior (return absolute).
        return abs
    }
}
