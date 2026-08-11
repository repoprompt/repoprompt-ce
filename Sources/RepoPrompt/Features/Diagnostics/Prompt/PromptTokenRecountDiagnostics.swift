import Foundation

#if DEBUG
    enum PromptTokenRecountDiagnostics {
        @TaskLocal static var correlationFields: [String: String] = [:]

        static func start() -> Double? {
            WorkspaceRestorePerfLog.timestampMSIfEnabled()
        }

        static func event(_ name: String, fields: [String: String] = [:]) {
            var mergedFields = correlationFields
            mergedFields.merge(fields) { _, new in new }
            WorkspaceRestorePerfLog.event(name, fields: mergedFields)
        }

        static func formatElapsedMS(since startMS: Double) -> String {
            WorkspaceRestorePerfLog.formatElapsedMS(since: startMS)
        }

        static func durationField(since startMS: Double?) -> String {
            startMS.map { formatElapsedMS(since: $0) } ?? "notMeasured"
        }

        static func selectionFields(_ selection: StoredSelection) -> [String: String] {
            WorkspaceSelectionDebugSignature.unprefixedFields(for: selection)
        }

        final class SelectedPathsState: @unchecked Sendable {
            private let lock = NSLock()
            private let selectedPathCount: Int
            private var finished = false
            private var currentIndex = -1
            private var currentPathLabel = "none"
            private var currentPathHash = "none"
            private var currentPhase = "notStarted"
            private var currentResolvedKind = "none"
            private var expandedFiles = 0
            private var filesRead = 0
            private var currentFileLabel = "none"
            private var currentFileHash = "none"
            private var lastProgressLoggedReadCount = 0
            private var lookupBatchActive = false
            private var readBatchScheduled = 0
            private var readBatchCompleted = 0
            private var readBatchActive = 0
            private var readBatchErrors = 0
            private var readBatchLimit = 0

            init(selectedPathCount: Int) {
                self.selectedPathCount = selectedPathCount
            }

            func beginLookupBatch() {
                lock.lock()
                lookupBatchActive = true
                currentPhase = "lookupBatch"
                currentResolvedKind = "none"
                lock.unlock()
            }

            func finishLookupBatch() {
                lock.lock()
                lookupBatchActive = false
                currentPhase = "lookupBatchEnd"
                lock.unlock()
            }

            func beginPath(index: Int, path: String) {
                lock.lock()
                currentIndex = index
                currentPathLabel = Self.boundedLabel(for: path)
                currentPathHash = Self.hashLabel(for: path)
                currentPhase = "begin"
                currentResolvedKind = "none"
                currentFileLabel = "none"
                currentFileHash = "none"
                lock.unlock()
            }

            func beginAssembly(index: Int, path: String, resolvedKind: String) {
                lock.lock()
                currentIndex = index
                currentPathLabel = Self.boundedLabel(for: path)
                currentPathHash = Self.hashLabel(for: path)
                currentPhase = "assembly"
                currentResolvedKind = resolvedKind
                currentFileLabel = "none"
                currentFileHash = "none"
                lock.unlock()
            }

            func setPhase(_ phase: String) {
                lock.lock()
                currentPhase = phase
                lock.unlock()
            }

            func resolutionEnd(resolvedKind: String) {
                lock.lock()
                currentPhase = "resolutionEnd"
                currentResolvedKind = resolvedKind
                lock.unlock()
            }

            func folderExpansionEnd(descendantCount: Int) {
                lock.lock()
                currentPhase = "folderExpansionEnd"
                expandedFiles += descendantCount
                lock.unlock()
            }

            func beginRead(file: WorkspaceFileRecord) {
                lock.lock()
                currentPhase = "read"
                currentFileLabel = Self.boundedLabel(for: file.standardizedFullPath)
                currentFileHash = Self.hashLabel(for: file.standardizedFullPath)
                lock.unlock()
            }

            func finishRead() {
                lock.lock()
                filesRead += 1
                lock.unlock()
            }

            func beginReadBatch(scheduled: Int, limit: Int) {
                lock.lock()
                currentPhase = "readBatch"
                readBatchScheduled = scheduled
                readBatchCompleted = 0
                readBatchActive = 0
                readBatchErrors = 0
                readBatchLimit = limit
                lock.unlock()
            }

            func beginBatchRead(index: Int, path: String, file: WorkspaceFileRecord) {
                lock.lock()
                currentIndex = index
                currentPathLabel = Self.boundedLabel(for: path)
                currentPathHash = Self.hashLabel(for: path)
                currentPhase = "readBatch"
                currentResolvedKind = "file"
                currentFileLabel = Self.boundedLabel(for: file.standardizedFullPath)
                currentFileHash = Self.hashLabel(for: file.standardizedFullPath)
                readBatchActive += 1
                lock.unlock()
            }

            func finishBatchRead(errorDescription: String?) {
                lock.lock()
                filesRead += 1
                readBatchCompleted += 1
                readBatchActive = max(0, readBatchActive - 1)
                if errorDescription != nil {
                    readBatchErrors += 1
                }
                lock.unlock()
            }

            func shouldLogReadProgress() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard filesRead >= 25 else { return false }
                guard filesRead == 25 || filesRead - lastProgressLoggedReadCount >= 100 else { return false }
                lastProgressLoggedReadCount = filesRead
                return true
            }

            func finish() {
                lock.lock()
                finished = true
                currentPhase = "finished"
                lock.unlock()
            }

            func snapshot() -> [String: String] {
                lock.lock()
                defer { lock.unlock() }
                return [
                    "finished": "\(finished)",
                    "index": currentIndex >= 0 ? "\(currentIndex + 1)" : "0",
                    "selectedPaths": "\(selectedPathCount)",
                    "pathLabel": currentPathLabel,
                    "pathHash": currentPathHash,
                    "phase": currentPhase,
                    "resolvedKind": currentResolvedKind,
                    "expandedFiles": "\(expandedFiles)",
                    "filesRead": "\(filesRead)",
                    "currentFileLabel": currentFileLabel,
                    "currentFileHash": currentFileHash,
                    "lookupBatchActive": "\(lookupBatchActive)",
                    "readBatchScheduled": "\(readBatchScheduled)",
                    "readBatchCompleted": "\(readBatchCompleted)",
                    "readBatchActive": "\(readBatchActive)",
                    "readBatchErrors": "\(readBatchErrors)",
                    "readBatchLimit": "\(readBatchLimit)"
                ]
            }

            static func boundedLabel(for path: String, maxLength: Int = 96) -> String {
                let standardized = (path as NSString).standardizingPath
                let components = (standardized as NSString).pathComponents.filter { $0 != "/" }
                let suffix = components.suffix(4).joined(separator: "/")
                let label = suffix.isEmpty ? standardized : suffix
                guard label.count > maxLength else { return label }
                return "…" + label.suffix(maxLength - 1)
            }

            static func hashLabel(for path: String) -> String {
                let standardized = (path as NSString).standardizingPath
                var hash: UInt64 = 14_695_981_039_346_656_037
                for byte in standardized.utf8 {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
                return String(hash, radix: 16)
            }

            static func resolvedKind(for issue: PathResolutionIssue?) -> String {
                guard let issue else { return "unresolved" }
                switch issue {
                case .ambiguousAlias, .ambiguousRootMatch:
                    return "ambiguous"
                case .emptyInput, .invalidPathCharacters, .pathOutsideWorkspace, .destinationOutsideSourceRoot, .unsupportedPseudoAbsoluteAlias:
                    return "error"
                case .unresolved:
                    return "unresolved"
                }
            }
        }
    }
#endif
