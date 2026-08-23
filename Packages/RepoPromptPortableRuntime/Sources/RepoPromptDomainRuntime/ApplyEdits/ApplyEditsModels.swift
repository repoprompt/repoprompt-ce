import Foundation

public enum ApplyEditsMode: Equatable {
    case rewrite(newText: String, onMissing: OnMissing)
    case single(search: String, replace: String, replaceAll: Bool)
    case batch([ApplyEditsOperation])
}

public struct ApplyEditsOperation: Equatable {
    public let search: String
    public let replace: String
    public let replaceAll: Bool

    public init(search: String, replace: String, replaceAll: Bool) {
        self.search = search
        self.replace = replace
        self.replaceAll = replaceAll
    }
}

public enum OnMissing: String, Equatable {
    case error
    case create
}

public struct ApplyEditsRequest: Equatable {
    public let path: String
    public let mode: ApplyEditsMode
    public let verbose: Bool

    public init(path: String, mode: ApplyEditsMode, verbose: Bool) {
        self.path = path
        self.mode = mode
        self.verbose = verbose
    }

    public var editCount: Int {
        switch mode {
        case .rewrite, .single:
            1
        case let .batch(edits):
            edits.count
        }
    }
}

public struct ApplyEditsExecutionOptions: Equatable, Sendable {
    public let includeToolCardUnifiedDiff: Bool

    public init(includeToolCardUnifiedDiff: Bool) {
        self.includeToolCardUnifiedDiff = includeToolCardUnifiedDiff
    }

    public static let `default` = ApplyEditsExecutionOptions(includeToolCardUnifiedDiff: true)
}

public enum ApplyEditsError: Swift.Error, Equatable {
    case invalidParams(String)
    case internalError(String)
}
