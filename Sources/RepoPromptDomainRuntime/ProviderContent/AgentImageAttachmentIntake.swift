import Foundation
import UniformTypeIdentifiers

// MARK: - Drop classification

/// Shared rules for deciding whether a drag carries images, used by the Agent Mode pane-wide drop
/// target and the composer text view so both highlight and accept the same drags.
package enum AgentImageDropClassifier {
    package enum Classification: Sendable, Equatable {
        /// The drag carries image data or at least one image file URL.
        case images
        /// The drag carries only text, non-image files, or other data.
        case notImages
        /// The drag carries file URLs that have not been read yet.
        case undetermined
    }

    package static let legacyPNGPasteboardType = "Apple PNG pasteboard type"
    package static let legacyTIFFPasteboardType = "NeXT TIFF v4.0 pasteboard type"

    package static func isImageTypeIdentifier(_ identifier: String) -> Bool {
        if identifier == legacyPNGPasteboardType || identifier == legacyTIFFPasteboardType {
            return true
        }
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .image)
    }

    package static func isImageFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image)
        {
            return true
        }
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Classifies a drag from its registered type identifiers and, when already readable, its file
    /// URLs. Pass `nil` for `fileURLs` when the drag advertises file URLs that are not loaded yet.
    package static func classify(typeIdentifiers: [String], fileURLs: [URL]?) -> Classification {
        if typeIdentifiers.contains(where: isImageTypeIdentifier) {
            return .images
        }
        guard let fileURLs else {
            return typeIdentifiers.contains(UTType.fileURL.identifier) ? .undetermined : .notImages
        }
        return fileURLs.contains(where: isImageFileURL) ? .images : .notImages
    }
}

// MARK: - Drop tracking

/// Tracks one pane-level image drag so asynchronous work lands on the tab that was current when
/// the drag began, and so a stale classification cannot relight a finished drag.
package struct AgentImageDropTracker: Sendable, Equatable {
    package private(set) var generation: UInt64 = 0
    package private(set) var capturedTabID: UUID?
    package private(set) var classification: AgentImageDropClassifier.Classification?

    package init() {}

    package var isActive: Bool {
        classification != nil
    }

    package var isHighlighted: Bool {
        classification == .images
    }

    @discardableResult
    package mutating func begin(tabID: UUID?, classification: AgentImageDropClassifier.Classification) -> UInt64 {
        generation &+= 1
        capturedTabID = tabID
        self.classification = classification
        return generation
    }

    /// Applies an asynchronous classification; ignored when the drag it belongs to is over.
    @discardableResult
    package mutating func resolve(_ classification: AgentImageDropClassifier.Classification, generation: UInt64) -> Bool {
        guard generation == self.generation, isActive else { return false }
        self.classification = classification
        return true
    }

    /// The pointer left the pane. The captured tab is kept until a drop or a new drag.
    package mutating func exit() {
        classification = nil
    }

    /// Returns the tab a drop must attach to and ends the drag.
    package mutating func takeDropTarget(fallbackTabID: UUID?) -> UUID? {
        let target = capturedTabID ?? fallbackTabID
        generation &+= 1
        capturedTabID = nil
        classification = nil
        return target
    }
}

// MARK: - Attach guard

package enum AgentImageAttachmentBlockReason: Sendable, Equatable {
    case noActiveTab
    case agentBusy
    case providerUnsupported(providerName: String)

    package var message: String {
        switch self {
        case .noActiveTab:
            "Images can't be attached without an active chat."
        case .agentBusy:
            "Images can't be attached while the agent is working. Try again when the turn finishes."
        case let .providerUnsupported(providerName):
            "\(providerName) doesn't support image attachments."
        }
    }
}

/// The single rule shared by the attach button, paste, and drop.
package enum AgentImageAttachmentGuard {
    package static func blockReason(
        hasTab: Bool,
        isAgentBusy: Bool,
        providerSupportsImages: Bool,
        providerName: String
    ) -> AgentImageAttachmentBlockReason? {
        guard hasTab else { return .noActiveTab }
        guard !isAgentBusy else { return .agentBusy }
        guard providerSupportsImages else { return .providerUnsupported(providerName: providerName) }
        return nil
    }
}

// MARK: - Availability

/// Cached, off-main `fileExists` lookups for attachment cards, so a redraw never touches the disk.
package final class AgentImageAttachmentAvailabilityResolver: @unchecked Sendable {
    package enum Availability: Sendable, Equatable {
        case available
        case missing
    }

    private static let maxCachedEntries = 2000

    private let lock = NSLock()
    private var cache: [String: Availability] = [:]
    private let fileExists: @Sendable (String) -> Bool
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    package init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        queue: DispatchQueue = DispatchQueue(label: "com.repoprompt.agent-attachment-availability", qos: .utility),
        callbackQueue: DispatchQueue = .main
    ) {
        self.fileExists = fileExists
        self.queue = queue
        self.callbackQueue = callbackQueue
    }

    /// The standardized local path a card checks, or `nil` for remote sources.
    package static func path(for attachment: AgentImageAttachment) -> String? {
        guard case let .localFile(path) = attachment.source else { return nil }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.isEmpty ? nil : standardized
    }

    package func cachedAvailability(forPath path: String) -> Availability? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    package func record(_ availability: Availability, forPath path: String) {
        lock.lock()
        if cache.count >= Self.maxCachedEntries, cache[path] == nil {
            cache.removeAll(keepingCapacity: true)
        }
        cache[path] = availability
        lock.unlock()
    }

    /// Resolves availability off the caller's thread (or from the cache) and calls back on the
    /// callback queue (the main queue by default).
    package func resolveAvailability(
        forPath path: String,
        completion: @escaping @Sendable (Availability) -> Void
    ) {
        if let cached = cachedAvailability(forPath: path) {
            callbackQueue.async { completion(cached) }
            return
        }
        queue.async { [self] in
            let availability: Availability = fileExists(path) ? .available : .missing
            record(availability, forPath: path)
            callbackQueue.async { completion(availability) }
        }
    }
}
