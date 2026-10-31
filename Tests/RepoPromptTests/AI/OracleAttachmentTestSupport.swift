import Foundation
import RepoPromptDomainRuntime

extension OracleAttachment {
    var bytes: Data {
        switch payload {
        case let .image(_, data), let .pdf(data), let .text(_, data), let .binary(data): data
        }
    }

    var imageMediaType: ImageMediaType? {
        if case let .image(mediaType, _) = payload { mediaType } else { nil }
    }
}
