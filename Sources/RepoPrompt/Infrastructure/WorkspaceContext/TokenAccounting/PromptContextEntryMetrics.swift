import Foundation
import OSLog

/// Tracks prompt-accounting record identity by model UUID and standardized path string.
/// This is not filesystem inode or symlink identity. The first accepted record wins;
/// later collisions on either key are rejected so both metric indexes stay coherent.
struct PromptContextAccountingIdentitySet {
    private var fileIDs = Set<UUID>()
    private var standardizedFullPaths = Set<String>()

    mutating func insert(fileID: UUID, standardizedFullPath: String) -> Bool {
        guard !fileIDs.contains(fileID),
              !standardizedFullPaths.contains(standardizedFullPath)
        else { return false }

        fileIDs.insert(fileID)
        standardizedFullPaths.insert(standardizedFullPath)
        return true
    }

    mutating func insert(_ entry: ResolvedPromptFileEntry) -> Bool {
        insert(
            fileID: entry.file.id,
            standardizedFullPath: entry.file.standardizedFullPath
        )
    }
}

struct PromptContextEntryMetric: Equatable {
    let fileID: UUID
    let standardizedFullPath: String
    let renderedDisplayPath: String
    let renderMode: PromptEntriesEvaluation.RenderMode
    let displayTokenCount: Int
    let displayPercentage: Double
    let includedLineCount: Int?
}

struct PromptContextEntryMetricsSnapshot: Equatable {
    #if DEBUG
        private static let identityLogger = Logger(
            subsystem: "com.repoprompt.prompt",
            category: "ContextAccountingIdentity"
        )
    #endif

    /// Authoritative total from the rendered selected-file payload. Defensive metric filtering
    /// never recomputes this denominator when it rejects a conflicting per-file index record.
    let totalSelectedDisplayTokens: Int
    let metricsByFileID: [UUID: PromptContextEntryMetric]
    let metricsByStandardizedFullPath: [String: PromptContextEntryMetric]

    static let empty = PromptContextEntryMetricsSnapshot(
        totalSelectedDisplayTokens: 0,
        metricsByFileID: [:],
        metricsByStandardizedFullPath: [:]
    )

    init(totalSelectedDisplayTokens: Int, metrics: [PromptContextEntryMetric]) {
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

    func metric(forFileID fileID: UUID) -> PromptContextEntryMetric? {
        metricsByFileID[fileID]
    }

    func metric(forStandardizedFullPath standardizedFullPath: String) -> PromptContextEntryMetric? {
        metricsByStandardizedFullPath[standardizedFullPath]
    }

    var renderedDisplayPathsByStandardizedFullPath: [String: String] {
        metricsByStandardizedFullPath.mapValues(\.renderedDisplayPath)
    }
}
