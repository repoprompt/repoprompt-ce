//
//  AIChatMessage.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-14.
//

import Foundation

// MARK: - Supporting Models

/// A persisted preview of an image that was attached to a user message. Stores
/// only a small downscaled thumbnail — never the full-resolution bytes — so
/// transcripts can render what was sent without bloating session files.
struct AIChatImageAttachment: Codable, Equatable, Identifiable {
    let id: UUID
    /// MIME type of the original image (e.g. "image/png").
    let mediaType: String
    /// Optional user/agent-supplied caption.
    let title: String?
    /// Downscaled preview bytes (JPEG), capped in dimension and size.
    let thumbnailData: Data

    init(
        id: UUID = UUID(),
        mediaType: String,
        title: String? = nil,
        thumbnailData: Data
    ) {
        self.id = id
        self.mediaType = mediaType
        self.title = title
        self.thumbnailData = thumbnailData
    }
}

struct AIChatMessage: Identifiable, Equatable {
    let id: UUID
    private(set) var content: String
    let isUser: Bool

    /// The sequence index determining message order.
    let sequenceIndex: Int
    private(set) var isFinalized: Bool = false
    private(set) var reasoningContent: String = ""

    /// The user's selected file paths at the time this message was created.
    private(set) var allowedFilePaths: [String] = []

    /// Image attachments sent with this message (thumbnails only).
    private(set) var imageAttachments: [AIChatImageAttachment] = []

    /// Quick access to how many files were selected when this message was created.
    var selectedFileCount: Int {
        allowedFilePaths.count
    }

    var revisionCount: Int = 0

    // Token counts for analytics
    private(set) var promptTokens: Int?
    private(set) var completionTokens: Int?
    private(set) var cost: Double?

    /// The AI model name (e.g. "gpt-4o", "Claude-Opus", etc.) associated with
    /// this assistant response.  `nil` for user messages or when unknown.
    private(set) var modelName: String?

    init(
        id: UUID = UUID(),
        content: String,
        isUser: Bool,
        isFinalized: Bool = false,
        sequenceIndex: Int = 0,
        allowedFilePaths: [String] = [],
        reasoningContent: String = "",
        modelName: String? = nil,
        imageAttachments: [AIChatImageAttachment] = []
    ) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.sequenceIndex = sequenceIndex
        self.allowedFilePaths = allowedFilePaths
        self.isFinalized = isFinalized
        self.reasoningContent = reasoningContent
        self.modelName = modelName
        self.imageAttachments = imageAttachments
    }

    static func == (lhs: AIChatMessage, rhs: AIChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.revisionCount == rhs.revisionCount
    }

    /// Updates the core `content` and increments revisionCount.
    mutating func updateContent(_ newContent: String) {
        content = newContent
        revisionCount += 1
    }

    /// Appends text to existing `content`, then increments revisionCount.
    mutating func appendContent(_ extra: String) {
        content += extra
        revisionCount += 1
    }

    mutating func updateReasoningContent(_ newReasoning: String) {
        reasoningContent = newReasoning
        revisionCount += 1
    }

    mutating func setIsFinalized(_ finalized: Bool) {
        isFinalized = finalized
        revisionCount += 1
    }

    mutating func updateTokenInfo(_ info: ChatTokenInfo?) {
        promptTokens = info?.promptTokens
        completionTokens = info?.completionTokens
        cost = info?.cost
        revisionCount += 1
    }

    mutating func setAllowedPaths(_ filePaths: [String]) {
        allowedFilePaths = filePaths
        revisionCount += 1
    }

    /// Make this message lightweight before deallocation to reduce release overhead.
    mutating func makeLightweight() {
        updateContent("")
        updateReasoningContent("")
        setAllowedPaths([])
        imageAttachments = []
    }
}
