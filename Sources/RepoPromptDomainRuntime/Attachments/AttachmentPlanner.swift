import Foundation

/// The initializer is `fileprivate`: `AttachmentPlanner` is the only producer, so an encoder cannot
/// invent a delivery the route's capability row does not declare.
package struct PlannedAttachment: Equatable {
    package enum Delivery: Equatable {
        case nativeImage(ImageMediaType, Data)
        case nativeDocument(Data)
        case inlineText(String)
    }

    package let attachment: OracleAttachment
    package let delivery: Delivery

    fileprivate init(attachment: OracleAttachment, delivery: Delivery) {
        self.attachment = attachment
        self.delivery = delivery
    }
}

package enum AttachmentRefusalReason: Error, Equatable {
    case routeCannotCarry
    case textExceedsInlineLimit(byteCount: Int, limit: Int)
}

package struct AttachmentRefusal: Equatable {
    package let index: Int
    package let fileName: String
    package let kind: AttachmentKind
    package let routeDisplayName: String
    package let reason: AttachmentRefusalReason

    package var message: String {
        "attachments[\(index)] \(fileName): \(reasonText)"
    }

    package var reasonText: String {
        switch reason {
        case .routeCannotCarry:
            "\(routeDisplayName) cannot carry \(Self.kindNoun(kind)) attachment. Remove it, or choose a model that can carry it."
        case let .textExceedsInlineLimit(byteCount, limit):
            "text file is \(Self.kibibytes(byteCount)) KiB, over the "
                + "\(Self.kibibytes(limit)) KiB inline limit for \(routeDisplayName). "
                + "Attach a smaller excerpt, or let the Oracle use read_file on the original."
        }
    }

    private static func kindNoun(_ kind: AttachmentKind) -> String {
        switch kind {
        case .image: "an image"
        case .pdf: "a PDF"
        case .text: "a text"
        case .binary: "a binary"
        }
    }

    private static func kibibytes(_ bytes: Int) -> Int {
        (bytes + 1023) / 1024
    }
}

package struct AttachmentRequestOverflow: Equatable {
    package let routeDisplayName: String
    package let encodedByteCount: Int
    package let limit: Int

    package var message: String {
        "Attachments encode to \(encodedByteCount) bytes, over the \(limit)-byte request limit of \(routeDisplayName)."
    }
}

package struct AttachmentAdmissionError: Error, Equatable, LocalizedError {
    package let refusals: [AttachmentRefusal]
    package let requestOverflow: AttachmentRequestOverflow?

    package var errorDescription: String? {
        let lines = refusals.map(\.message) + [requestOverflow?.message].compactMap(\.self)
        return lines.joined(separator: "\n")
    }
}

package enum AttachmentPlanner {
    /// Pure: the same inputs always give the same answer, so admission and message building can each
    /// call it without sharing state. Per-file count and byte caps belong to the loader; the planner
    /// enforces route capability, the inline text cap, and the route's encoded request cap.
    package static func plan(
        _ set: OracleAttachmentSet,
        route: AttachmentRoute,
        limits: OracleAttachmentLimits
    ) -> Result<[PlannedAttachment], AttachmentAdmissionError> {
        let capability = AttachmentRouteCapability.capability(for: route)
        var planned: [PlannedAttachment] = []
        var refusals: [AttachmentRefusal] = []
        var totalEncodedBytes = 0

        for (index, attachment) in set.attachments.enumerated() {
            switch delivery(for: attachment, capability: capability, limits: limits) {
            case let .success(delivery):
                totalEncodedBytes += encodedByteCount(of: delivery)
                planned.append(PlannedAttachment(attachment: attachment, delivery: delivery))
            case let .failure(reason):
                refusals.append(AttachmentRefusal(
                    index: index,
                    fileName: attachment.fileName,
                    kind: attachment.kind,
                    routeDisplayName: capability.displayName,
                    reason: reason
                ))
            }
        }

        var overflow: AttachmentRequestOverflow?
        if let limit = capability.maxEncodedRequestBytes, totalEncodedBytes > limit {
            overflow = AttachmentRequestOverflow(
                routeDisplayName: capability.displayName,
                encodedByteCount: totalEncodedBytes,
                limit: limit
            )
        }
        guard refusals.isEmpty, overflow == nil else {
            return .failure(AttachmentAdmissionError(refusals: refusals, requestOverflow: overflow))
        }
        return .success(planned)
    }

    private static func delivery(
        for attachment: OracleAttachment,
        capability: AttachmentRouteCapability,
        limits: OracleAttachmentLimits
    ) -> Result<PlannedAttachment.Delivery, AttachmentRefusalReason> {
        if let reason = refusalReason(
            kind: attachment.kind,
            byteCount: attachment.payload.byteCount,
            capability: capability,
            limits: limits
        ) {
            return .failure(reason)
        }
        switch attachment.payload {
        case let .image(mediaType, data):
            return .success(.nativeImage(mediaType, data))
        case let .pdf(data):
            return .success(.nativeDocument(data))
        case let .text(text, _):
            return .success(.inlineText(AttachmentInlineText.render(
                text: text,
                fileName: attachment.fileName,
                title: attachment.normalizedTitle
            )))
        case .binary:
            return .failure(.routeCannotCarry)
        }
    }

    /// Whether a file of `kind` and `byteCount` is refused on a route before any bytes are read, so a
    /// surface that only knows the persisted facts can warn ahead of the request.
    static func refusalReason(
        kind: AttachmentKind,
        byteCount: Int,
        capability: AttachmentRouteCapability,
        limits: OracleAttachmentLimits
    ) -> AttachmentRefusalReason? {
        switch kind {
        case .image:
            switch capability.image {
            case .nativeImage: nil
            case .unsupported: .routeCannotCarry
            }
        case .pdf:
            switch capability.pdf {
            case .nativeDocument: nil
            case .unsupported: .routeCannotCarry
            }
        case .text:
            switch capability.text {
            case .inlineText:
                byteCount > limits.maxInlineTextBytes
                    ? .textExceedsInlineLimit(byteCount: byteCount, limit: limits.maxInlineTextBytes)
                    : nil
            case .unsupported: .routeCannotCarry
            }
        case .binary:
            switch capability.binary {
            case .unsupported: .routeCannotCarry
            }
        }
    }

    /// Base64 length for byte payloads, UTF-8 length for text.
    private static func encodedByteCount(of delivery: PlannedAttachment.Delivery) -> Int {
        switch delivery {
        case let .nativeImage(_, data), let .nativeDocument(data): (data.count + 2) / 3 * 4
        case let .inlineText(block): block.utf8.count
        }
    }
}
