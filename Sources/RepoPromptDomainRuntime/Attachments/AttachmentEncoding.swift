import Foundation

/// The planner is the only producer of `PlannedAttachment`, so this is unreachable while a route's row
/// and its encoder agree. The matrix test in `Tests/RepoPromptDomainRuntimeTests/Attachments` is what
/// checks that agreement. The compiler does not: a new `AttachmentKind` case does not force a route to
/// answer it, and a row may still declare `.unsupported`. A wrong row must fail one request, so this
/// is a thrown error and never a precondition.
package enum AttachmentEncodingInvariant: Error, Equatable, LocalizedError {
    case rungNotDeclared(fileName: String, kind: AttachmentKind, route: AttachmentRoute)
    case unencodable(fileName: String, route: AttachmentRoute)

    package var errorDescription: String? {
        switch self {
        case let .rungNotDeclared(fileName, kind, route):
            let name = AttachmentRouteCapability.capability(for: route).displayName
            return "\(fileName): the \(name) encoder received a \(kind.rawValue) attachment its capability row does not declare."
        case let .unencodable(fileName, route):
            let name = AttachmentRouteCapability.capability(for: route).displayName
            return "\(fileName): the \(name) encoder could not build a request part for it."
        }
    }
}

package extension PlannedAttachment {
    func undeclaredRung(on route: AttachmentRoute) -> AttachmentEncodingInvariant {
        .rungNotDeclared(fileName: attachment.fileName, kind: attachment.kind, route: route)
    }

    var inlineTextBlock: String? {
        switch delivery {
        case let .inlineText(block): block
        case .nativeImage, .nativeDocument: nil
        }
    }

    /// Inline text carries its title inside its own block.
    var titleAnnotation: String? {
        guard let title = attachment.normalizedTitle else { return nil }
        switch delivery {
        case .nativeImage: return "Image title: \(title)"
        case .nativeDocument: return "Document title: \(title)"
        case .inlineText: return nil
        }
    }
}

package enum AttachmentEncoding {
    /// Admission calls the same pure planner earlier, so this only fails when a caller bypassed
    /// admission. The error names every refused file.
    package static func plan(
        _ attachments: [OracleAttachment],
        route: AttachmentRoute
    ) throws(AttachmentAdmissionError) -> [PlannedAttachment] {
        guard !attachments.isEmpty else { return [] }
        switch AttachmentPlanner.plan(OracleAttachmentSet(attachments), route: route, limits: .production) {
        case let .success(planned): return planned
        case let .failure(error): throw error
        }
    }

    package static func prependingInlineText(of planned: [PlannedAttachment], to body: String) -> String {
        let blocks = planned.compactMap(\.inlineTextBlock)
        guard !blocks.isEmpty else { return body }
        return (blocks + (body.isEmpty ? [] : [body])).joined(separator: "\n\n")
    }

    package static func dataURL(mimeType: String, data: Data) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    package static func textOnlyBody(
        for attachments: [OracleAttachment],
        route: AttachmentRoute,
        body: String
    ) throws -> String {
        let planned = try plan(attachments, route: route)
        for item in planned {
            switch item.delivery {
            case .inlineText: break
            case .nativeImage, .nativeDocument: throw item.undeclaredRung(on: route)
            }
        }
        return prependingInlineText(of: planned, to: body)
    }
}
