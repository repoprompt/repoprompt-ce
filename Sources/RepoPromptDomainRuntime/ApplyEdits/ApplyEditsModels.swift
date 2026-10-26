import Foundation

package enum ApplyEditsMode: Equatable {
    case rewrite(newText: String, onMissing: OnMissing)
    case single(search: String, replace: String, replaceAll: Bool)
    case batch([ApplyEditsOperation])
}

package struct ApplyEditsOperation: Equatable {
    package let search: String
    package let replace: String
    package let replaceAll: Bool

    package init(search: String, replace: String, replaceAll: Bool) {
        self.search = search
        self.replace = replace
        self.replaceAll = replaceAll
    }
}

package enum OnMissing: String, Equatable {
    case error
    case create
}

package struct ApplyEditsRequest: Equatable {
    package let path: String
    package let mode: ApplyEditsMode
    package let verbose: Bool

    package init(path: String, mode: ApplyEditsMode, verbose: Bool) {
        self.path = path
        self.mode = mode
        self.verbose = verbose
    }

    package var editCount: Int {
        switch mode {
        case .rewrite, .single:
            1
        case let .batch(edits):
            edits.count
        }
    }
}

package struct ApplyEditsExecutionOptions: Equatable {
    package let includeToolCardUnifiedDiff: Bool

    package init(includeToolCardUnifiedDiff: Bool) {
        self.includeToolCardUnifiedDiff = includeToolCardUnifiedDiff
    }

    package static let `default` = ApplyEditsExecutionOptions(includeToolCardUnifiedDiff: true)
}

package enum ApplyEditsError: Swift.Error, Equatable {
    case invalidParams(String)
    case internalError(String)
}
