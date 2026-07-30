import CryptoKit
import Foundation

#if DEBUG
    enum WorkspaceSelectionDebugSignature {
        static func fields(for selection: StoredSelection, prefix: String = "selection") -> [String: String] {
            var result = counts(for: selection, prefix: prefix)
            result["\(prefix)Signature"] = signature(for: selection)
            return result
        }

        static func counts(for selection: StoredSelection, prefix: String = "selection") -> [String: String] {
            [
                "\(prefix)SelectedPaths": "\(selection.selectedPaths.count)",
                "\(prefix)ManualCodemapPaths": "\(selection.manualCodemapPaths.count)",
                "\(prefix)SliceFiles": "\(selection.slices.count)",
                "\(prefix)SliceRanges": "\(sliceRangeCount(in: selection))",
                "\(prefix)CodemapAutoEnabled": "\(selection.codemapAutoEnabled)"
            ]
        }

        static func unprefixedFields(for selection: StoredSelection) -> [String: String] {
            [
                "selectionSignature": signature(for: selection),
                "selectedPaths": "\(selection.selectedPaths.count)",
                "manualCodemapPaths": "\(selection.manualCodemapPaths.count)",
                "sliceFiles": "\(selection.slices.count)",
                "sliceRanges": "\(sliceRangeCount(in: selection))",
                "codemapAutoEnabled": "\(selection.codemapAutoEnabled)"
            ]
        }

        static func signature(for selection: StoredSelection) -> String {
            let payload = canonicalLines(for: selection).joined(separator: "\n")
            let digest = SHA256.hash(data: Data(payload.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return String(hex.prefix(16))
        }

        private static func canonicalLines(for selection: StoredSelection) -> [String] {
            var lines: [String] = [
                "v2",
                "codemapAutoEnabled=\(selection.codemapAutoEnabled)",
                "selectedPaths.count=\(selection.selectedPaths.count)",
                "manualCodemapPaths.count=\(selection.manualCodemapPaths.count)",
                "sliceFiles.count=\(selection.slices.count)",
                "sliceRanges.count=\(sliceRangeCount(in: selection))"
            ]

            for path in selection.selectedPaths {
                lines.append("selected=\(standardized(path))")
            }
            for path in selection.manualCodemapPaths {
                lines.append("manualCodemap=\(standardized(path))")
            }
            let standardizedSlices = selection.slices.reduce(into: [String: [LineRange]]()) { partial, entry in
                partial[standardized(entry.key), default: []].append(contentsOf: entry.value)
            }
            for key in standardizedSlices.keys.sorted() {
                lines.append("slice=\(key)")
                for range in standardizedSlices[key] ?? [] {
                    lines.append("range=\(range.start)-\(range.end)")
                }
            }
            return lines
        }

        private static func standardized(_ path: String) -> String {
            StandardizedPath.absolute(path)
        }

        private static func sliceRangeCount(in selection: StoredSelection) -> Int {
            selection.slices.values.reduce(0) { $0 + $1.count }
        }
    }
#endif
