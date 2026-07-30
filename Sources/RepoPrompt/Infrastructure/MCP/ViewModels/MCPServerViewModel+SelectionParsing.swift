import Foundation
import MCP

extension MCPServerViewModel {
    struct ManageSelectionInputs {
        let paths: [String]
        let sliceInputs: [WorkspaceSelectionSliceInput]
        let sliceErrors: [String]
        let hadExplicitSliceSpec: Bool
    }

    nonisolated static func isLineRangeSuffix(_ suffix: Substring) -> Bool {
        guard let first = suffix.first, first == "L" || first == "l" else { return false }
        let remainder = suffix.dropFirst()
        guard !remainder.isEmpty else { return false }
        let sanitized = remainder.filter { !$0.isWhitespace }
        guard let firstDigit = sanitized.first, firstDigit.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789,-;")
        for scalar in sanitized.unicodeScalars where !allowed.contains(scalar) {
            return false
        }
        return true
    }

    nonisolated func parseManageSelectionInputs(rawPaths: [String], slicesValue: Value?) -> ManageSelectionInputs {
        var sanitizedPaths: [String] = []
        var seenPaths = Set<String>()
        var sliceInputs: [WorkspaceSelectionSliceInput] = []
        var sliceErrors: [String] = []
        var hadExplicitSlices = false

        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var pathComponent = trimmed
            var ranges: [LineRange] = []

            if let hashIndex = trimmed.lastIndex(of: "#") {
                let suffixStart = trimmed.index(after: hashIndex)
                if suffixStart < trimmed.endIndex {
                    let suffix = String(trimmed[suffixStart...])
                    if Self.isLineRangeSuffix(trimmed[suffixStart...]) {
                        hadExplicitSlices = true
                        let base = String(trimmed[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !base.isEmpty {
                            pathComponent = base
                        }
                        let payload = String(suffix.dropFirst())
                        let (parsed, invalidTokens) = Self.parseLineRangeTokens(from: payload)
                        ranges.append(contentsOf: parsed)
                        if !invalidTokens.isEmpty {
                            let messages = invalidTokens.map { "Invalid slice '\($0)' for path '\(trimmed)'" }
                            sliceErrors.append(contentsOf: messages)
                        }
                    }
                }
            }

            if !seenPaths.contains(pathComponent) {
                sanitizedPaths.append(pathComponent)
                seenPaths.insert(pathComponent)
            }

            if !ranges.isEmpty {
                sliceInputs.append(.init(path: pathComponent, ranges: ranges))
            }
        }

        if let slicesArray = slicesValue?.arrayValue {
            if !slicesArray.isEmpty {
                hadExplicitSlices = true
            }
            for entry in slicesArray {
                guard let obj = entry.objectValue else { continue }
                let rawPath = obj["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rawPath.isEmpty else { continue }

                var ranges: [LineRange] = []
                var explicitRangeSpecified = false

                if let rangesArray = obj["ranges"]?.arrayValue {
                    explicitRangeSpecified = true
                    for value in rangesArray {
                        guard let rangeObj = value.objectValue else { continue }
                        let start1 = rangeObj["start_line"]?.intValue
                        let start2 = rangeObj["start_line"]?.stringValue.flatMap(Int.init)
                        let start3 = rangeObj["start"]?.intValue
                        let start4 = rangeObj["start"]?.stringValue.flatMap(Int.init)
                        let startValue = start1 ?? start2 ?? start3 ?? start4

                        let end1 = rangeObj["end_line"]?.intValue
                        let end2 = rangeObj["end_line"]?.stringValue.flatMap(Int.init)
                        let end3 = rangeObj["end"]?.intValue
                        let end4 = rangeObj["end"]?.stringValue.flatMap(Int.init)
                        let endValue = end1 ?? end2 ?? end3 ?? end4

                        if let start = startValue {
                            let finalEnd = endValue ?? start
                            let rawDescription = rangeObj["description"]?.stringValue
                                ?? rangeObj["desc"]?.stringValue
                                ?? rangeObj["label"]?.stringValue
                            let trimmedDescription = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let description = (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil
                            ranges.append(LineRange(start: start, end: finalEnd, description: description))
                        } else {
                            sliceErrors.append("Invalid slice range for path '\(rawPath)': missing start_line")
                        }
                    }
                }

                if let linesString = obj["lines"]?.stringValue {
                    explicitRangeSpecified = true
                    let (parsed, invalidTokens) = Self.parseLineRangeTokens(from: linesString)
                    ranges.append(contentsOf: parsed)
                    if !invalidTokens.isEmpty {
                        let messages = invalidTokens.map { "Invalid slice '\($0)' for path '\(rawPath)'" }
                        sliceErrors.append(contentsOf: messages)
                    }
                }

                if explicitRangeSpecified {
                    sliceInputs.append(.init(path: rawPath, ranges: ranges))
                }
            }
        }

        return ManageSelectionInputs(
            paths: sanitizedPaths,
            sliceInputs: sliceInputs,
            sliceErrors: sliceErrors,
            hadExplicitSliceSpec: hadExplicitSlices || !sliceInputs.isEmpty
        )
    }

    nonisolated static func parseLineRangeTokens(from text: String) -> ([LineRange], [String]) {
        let compact = text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return ([], []) }

        let rawTokens = compact.split { ",;".contains($0) }
        var ranges: [LineRange] = []
        var invalid: [String] = []

        for rawToken in rawTokens {
            var token = String(rawToken)
            if token.isEmpty {
                continue
            }
            if token.lowercased().hasPrefix("l") {
                token.removeFirst()
            }
            if token.isEmpty {
                invalid.append(String(rawToken))
                continue
            }

            if let dashIndex = token.firstIndex(of: "-") {
                let startPart = String(token[..<dashIndex])
                let endPart = String(token[token.index(after: dashIndex)...])
                if let start = Int(startPart) {
                    let end = Int(endPart) ?? start
                    ranges.append(LineRange(start: start, end: end))
                } else {
                    invalid.append(String(rawToken))
                }
            } else if let value = Int(token) {
                ranges.append(LineRange(start: value, end: value))
            } else {
                invalid.append(String(rawToken))
            }
        }

        return (ranges, invalid)
    }
}
