import Foundation
import OSLog

/// Tracks prompt-accounting record identity by model UUID and standardized path string.
/// This is not filesystem inode or symlink identity. The first accepted record wins;
/// later collisions on either key are rejected so both metric indexes stay coherent.
package struct PromptContextAccountingIdentitySet {
    private var fileIDs = Set<UUID>()
    private var standardizedFullPaths = Set<String>()

    package mutating func insert(fileID: UUID, standardizedFullPath: String) -> Bool {
        guard !fileIDs.contains(fileID),
              !standardizedFullPaths.contains(standardizedFullPath)
        else { return false }

        fileIDs.insert(fileID)
        standardizedFullPaths.insert(standardizedFullPath)
        return true
    }

    package mutating func insert(_ entry: ResolvedPromptFileEntry) -> Bool {
        insert(
            fileID: entry.file.id,
            standardizedFullPath: entry.file.standardizedFullPath
        )
    }
}

package struct PromptContextEntryMetric: Equatable {
    package let fileID: UUID
    package let standardizedFullPath: String
    package let renderedDisplayPath: String
    package let renderMode: PromptEntriesEvaluation.RenderMode
    package let displayTokenCount: Int
    package let displayPercentage: Double
    package let includedLineCount: Int?
}

package struct PromptContextEntryMetricsSnapshot: Equatable {
    #if DEBUG
        private static let identityLogger = Logger(
            subsystem: "com.repoprompt.prompt",
            category: "ContextAccountingIdentity"
        )
    #endif

    /// Authoritative total from the rendered selected-file payload. Defensive metric filtering
    /// never recomputes this denominator when it rejects a conflicting per-file index record.
    package let totalSelectedDisplayTokens: Int
    let metricsByFileID: [UUID: PromptContextEntryMetric]
    let metricsByStandardizedFullPath: [String: PromptContextEntryMetric]

    package static let empty = PromptContextEntryMetricsSnapshot(
        totalSelectedDisplayTokens: 0,
        metricsByFileID: [:],
        metricsByStandardizedFullPath: [:]
    )

    package init(totalSelectedDisplayTokens: Int, metrics: [PromptContextEntryMetric]) {
        self.totalSelectedDisplayTokens = totalSelectedDisplayTokens

        var identities = PromptContextAccountingIdentitySet()
        var metricsByFileID: [UUID: PromptContextEntryMetric] = [:]
        var metricsByStandardizedFullPath: [String: PromptContextEntryMetric] = [:]
        for metric in metrics {
            guard identities.insert(
                fileID: metric.fileID,
                standardizedFullPath: metric.standardizedFullPath
            ) else {
                #if DEBUG
                    Self.identityLogger.fault(
                        "Dropped conflicting per-file metric while preserving authoritative totalSelectedDisplayTokens=\(totalSelectedDisplayTokens, privacy: .public)"
                    )
                #endif
                continue
            }
            metricsByFileID[metric.fileID] = metric
            metricsByStandardizedFullPath[metric.standardizedFullPath] = metric
        }
        self.metricsByFileID = metricsByFileID
        self.metricsByStandardizedFullPath = metricsByStandardizedFullPath
    }

    private init(
        totalSelectedDisplayTokens: Int,
        metricsByFileID: [UUID: PromptContextEntryMetric],
        metricsByStandardizedFullPath: [String: PromptContextEntryMetric]
    ) {
        self.totalSelectedDisplayTokens = totalSelectedDisplayTokens
        self.metricsByFileID = metricsByFileID
        self.metricsByStandardizedFullPath = metricsByStandardizedFullPath
    }

    package func metric(forFileID fileID: UUID) -> PromptContextEntryMetric? {
        metricsByFileID[fileID]
    }

    package func metric(forStandardizedFullPath standardizedFullPath: String) -> PromptContextEntryMetric? {
        metricsByStandardizedFullPath[standardizedFullPath]
    }

    var renderedDisplayPathsByStandardizedFullPath: [String: String] {
        metricsByStandardizedFullPath.mapValues(\.renderedDisplayPath)
    }
}
