import Foundation

private let standardizedPathSlashTrim = CharacterSet(charactersIn: "/")

package enum StandardizedPath {
    /// Returns a native Swift string. `standardizingPath` hands back a lazily bridged
    /// `NSPathStore2`, and every later comparison or hash of a bridged string goes through
    /// `NSString` and Unicode normalization; catalog sorts were two orders of magnitude slower.
    @inline(__always)
    package static func absolute(_ path: String) -> String {
        var standardized = (path as NSString).standardizingPath
        standardized.makeContiguousUTF8()
        return standardized
    }

    /// Canonical lexical path for a configured workspace root.
    /// Trims surrounding whitespace, rejects empty/NUL/`file://` values, expands leading `~`,
    /// standardizes separators, `.`, `..`, trailing `/`, and macOS `/private` aliases, and
    /// resolves relative paths via `standardizedFileURL` so store keys and root records agree.
    package static func canonicalWorkspaceRootPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsNUL(trimmed),
              !trimmed.lowercased().hasPrefix("file://")
        else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = absolute(expanded)
        let resolved = URL(fileURLWithPath: standardized, isDirectory: true).standardizedFileURL.path
        return absolute(resolved)
    }

    /// Canonical, deduplicated workspace root paths in declaration order (invalid entries omitted).
    package static func canonicalWorkspaceRootPaths(_ rawPaths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(rawPaths.count)
        for rawPath in rawPaths {
            guard let canonical = canonicalWorkspaceRootPath(rawPath),
                  seen.insert(canonical).inserted
            else { continue }
            ordered.append(canonical)
        }
        return ordered
    }

    @inline(__always)
    package static func relative(_ path: String) -> String {
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
    package static func join(standardizedRoot: String, standardizedRelativePath: String) -> String {
        guard !standardizedRelativePath.isEmpty else { return standardizedRoot }
        return standardizedRoot.hasSuffix("/")
            ? standardizedRoot + standardizedRelativePath
            : standardizedRoot + "/" + standardizedRelativePath
    }

    @inline(__always)
    package static func containsNUL(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.value == 0 }
    }

    package static func diagnosticEscaped(_ path: String) -> String {
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
    package static func isDescendant(_ standardizedPath: String, of standardizedParent: String) -> Bool {
        if standardizedPath == standardizedParent { return true }
        let prefix = standardizedParent.hasSuffix("/") ? standardizedParent : standardizedParent + "/"
        return standardizedPath.hasPrefix(prefix)
    }
}
