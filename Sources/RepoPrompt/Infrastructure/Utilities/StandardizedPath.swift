import Foundation

enum GitDiffPathNormalization {
    @inline(__always)
    static func normalizedAbsolutePath(_ path: String) -> String {
        StandardizedPath.absolute(path).precomposedStringWithCanonicalMapping
    }

    static func normalizedAbsolutePaths(_ paths: [String]) -> [String] {
        paths.map(normalizedAbsolutePath)
    }

    static func gitPathspecs(from paths: [String], repoRootPath: String) -> [String] {
        let standardizedRoot = normalizedAbsolutePath(repoRootPath)
        return paths.map { rawPath in
            let expanded = (rawPath as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return rawPath }

            let standardizedPath = normalizedAbsolutePath(expanded)
            guard StandardizedPath.isDescendant(standardizedPath, of: standardizedRoot) else {
                return standardizedPath
            }
            guard standardizedPath != standardizedRoot else { return "." }

            let suffix: Substring = if standardizedRoot == "/" {
                standardizedPath.dropFirst()
            } else {
                standardizedPath.dropFirst(standardizedRoot.count)
            }
            return StandardizedPath.relative(String(suffix))
        }
    }

    static func gitRelativePaths(from absolutePaths: [String], repoRootPath: String) -> [String] {
        let standardizedRoot = normalizedAbsolutePath(repoRootPath)
        var results: [String] = []
        results.reserveCapacity(absolutePaths.count)
        for abs in absolutePaths {
            let standardizedAbs = normalizedAbsolutePath(abs)
            guard StandardizedPath.isDescendant(standardizedAbs, of: standardizedRoot) else { continue }
            guard standardizedAbs != standardizedRoot else { continue }
            let suffix: Substring = if standardizedRoot == "/" {
                standardizedAbs.dropFirst()
            } else {
                standardizedAbs.dropFirst(standardizedRoot.count)
            }
            let relative = StandardizedPath.relative(String(suffix))
            guard !relative.isEmpty else { continue }
            results.append(relative)
        }
        return results
    }
}
