import Foundation

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
        metricsByFileID = Dictionary(
            uniqueKeysWithValues: metrics.map { ($0.fileID, $0) }
        )
        metricsByStandardizedFullPath = Dictionary(
            uniqueKeysWithValues: metrics.map { ($0.standardizedFullPath, $0) }
        )
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
