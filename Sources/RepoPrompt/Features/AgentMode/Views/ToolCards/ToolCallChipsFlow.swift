import SwiftUI

/// Displays tool calls as a single wrapping Text with inline SF Symbol icons.
/// No custom Layout, no GeometryReader — just Text concatenation that wraps naturally.
struct ToolCallChipsFlow: View {
    let toolNames: [String]
    let toolNameCounts: [String: Int]
    let keyPaths: [String]
    let lineLimit: Int
    let maxVisiblePaths: Int

    init(
        toolNames: [String],
        toolNameCounts: [String: Int],
        keyPaths: [String],
        lineLimit: Int = 3,
        maxVisiblePaths: Int = 4
    ) {
        self.toolNames = toolNames
        self.toolNameCounts = toolNameCounts
        self.keyPaths = keyPaths
        self.lineLimit = max(1, lineLimit)
        self.maxVisiblePaths = max(0, maxVisiblePaths)
    }

    var body: some View {
        let parts = buildParts()
        if !parts.isEmpty {
            parts.reduce(Text("")) { result, part in
                result + (result == Text("") ? Text("") : Text("  ")) + part
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(lineLimit)
            .truncationMode(.tail)
        }
    }

    private func buildParts() -> [Text] {
        var parts: [Text] = []

        // Deduplicate tool names preserving order
        var seen = Set<String>()
        let unique: [String]
        if !toolNameCounts.isEmpty {
            var result: [String] = []
            for name in toolNames {
                let key = name.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(name)
                }
            }
            for key in toolNameCounts.keys.sorted() where !seen.contains(key.lowercased()) {
                result.append(key)
            }
            unique = result
        } else {
            unique = toolNames.filter { let k = $0.lowercased()
                if seen.contains(k) {
                    return false
                }
                seen.insert(k)
                return true
            }
        }

        for name in unique {
            let count = toolNameCounts[name] ?? toolNameCounts[name.lowercased()] ?? 1
            let display = toolDisplayName(for: name)
            let icon = toolIcon(for: name)
            let label = count > 1 ? "\(display) ×\(count)" : display
            parts.append(Text(Image(systemName: icon)) + Text(" " + label))
        }

        // File paths as trailing items
        let visible = Array(keyPaths.prefix(maxVisiblePaths))
        let remaining = keyPaths.count - visible.count
        for path in visible {
            let name = fileName(from: path)
            parts.append(
                Text(Image(systemName: "doc")).foregroundColor(.primary.opacity(0.75))
                    + Text(" " + name).foregroundColor(.primary.opacity(0.80))
            )
        }
        if remaining > 0 {
            parts.append(Text("+\(remaining)").foregroundColor(.primary.opacity(0.75)))
        }

        return parts
    }
}
