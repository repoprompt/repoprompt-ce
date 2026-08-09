import Foundation

/// Maintains the one-to-one file-ID/path identity required by prompt accounting.
/// The first accepted entry wins; later collisions on either key are rejected.
struct PromptContextPhysicalFileIdentitySet {
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

        var identities = PromptContextPhysicalFileIdentitySet()
        var metricsByFileID: [UUID: PromptContextEntryMetric] = [:]
        var metricsByStandardizedFullPath: [String: PromptContextEntryMetric] = [:]
        for metric in metrics where identities.insert(
            fileID: metric.fileID,
            standardizedFullPath: metric.standardizedFullPath
        ) {
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
