import Foundation

private let standardizedPathSlashTrim = CharacterSet(charactersIn: "/")

enum StandardizedPath {
    @inline(__always)
    static func absolute(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    @inline(__always)
    static func relative(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: standardizedPathSlashTrim)
        guard !trimmed.isEmpty, trimmed != "." else { return "" }

        var components: [Substring] = []
        components.reserveCapacity(trimmed.split(separator: "/", omittingEmptySubsequences: true).count)
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        return components.map(String.init).joined(separator: "/")
    }

    @inline(__always)
    static func join(standardizedRoot: String, standardizedRelativePath: String) -> String {
        guard !standardizedRelativePath.isEmpty else { return standardizedRoot }
        return standardizedRoot.hasSuffix("/")
            ? standardizedRoot + standardizedRelativePath
            : standardizedRoot + "/" + standardizedRelativePath
    }

    @inline(__always)
    static func containsNUL(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.value == 0 }
    }

    static func diagnosticEscaped(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 0:
                escaped += "\\0"
            case 8:
                escaped += "\\b"
            case 9:
                escaped += "\\t"
            case 10:
                escaped += "\\n"
            case 12:
                escaped += "\\f"
            case 13:
                escaped += "\\r"
            case 0x1B:
                escaped += "\\e"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    @inline(__always)
    static func isDescendant(_ standardizedPath: String, of standardizedParent: String) -> Bool {
        if standardizedPath == standardizedParent { return true }
        let prefix = standardizedParent.hasSuffix("/") ? standardizedParent : standardizedParent + "/"
        return standardizedPath.hasPrefix(prefix)
    }
}

enum StoredSelectionPathNormalization {
    /// Canonicalizes stored selection path state.
    /// Policy: canonical absolute keys win over legacy/raw variants for the same file.
    static func standardizedPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return StandardizedPath.absolute(trimmed)
    }

    static func standardizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(paths.count)
        for rawPath in paths {
            guard let standardized = standardizedPath(rawPath), seen.insert(standardized).inserted else { continue }
            result.append(standardized)
        }
        return result
    }

    static func standardizedSlices(_ slices: [String: [LineRange]]) -> [String: [LineRange]] {
        guard !slices.isEmpty else { return [:] }

        var canonical: [String: [LineRange]] = [:]
        var legacyFallbacks: [String: [LineRange]] = [:]

        for (rawPath, ranges) in slices where !ranges.isEmpty {
            guard let standardized = standardizedPath(rawPath) else { continue }
            if rawPath == standardized {
                canonical[standardized] = ranges
                continue
            }

            if var existing = legacyFallbacks[standardized] {
                existing.append(contentsOf: ranges)
                legacyFallbacks[standardized] = SliceRangeMath.normalize(existing)
            } else {
                legacyFallbacks[standardized] = ranges
            }
        }

        for (path, ranges) in legacyFallbacks where canonical[path] == nil {
            canonical[path] = ranges
        }
        return canonical
    }
}

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
