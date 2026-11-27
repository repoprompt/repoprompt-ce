import Foundation

/// Signaling and a short-lived control lease for one workspace. Media travels over WebRTC.
public struct RemoteWorkspaceVoiceRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case start
        case status
        case end
    }

    public let action: Action
    public let callID: UUID
    public let workspaceID: UUID
    public let offerSDP: String?

    public init(action: Action, callID: UUID, workspaceID: UUID, offerSDP: String? = nil) {
        self.action = action
        self.callID = callID
        self.workspaceID = workspaceID
        self.offerSDP = offerSDP
    }

    public var isValid: Bool {
        switch action {
        case .start:
            guard let offerSDP else { return false }
            return offerSDP.hasPrefix("v=0") && offerSDP.utf8.count <= 64 * 1024
        case .status, .end:
            return offerSDP == nil
        }
    }
}

public struct RemoteWorkspaceVoiceLine: Codable, Sendable, Equatable, Identifiable {
    public enum Speaker: String, Codable, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let speaker: Speaker
    public let text: String

    public init(id: UUID = UUID(), speaker: Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

public struct RemoteWorkspaceVoiceStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case connecting
        case ready
        case ended
        case failed
    }

    public let callID: UUID
    public let workspaceID: UUID
    public let phase: Phase
    public let answerSDP: String?
    public let lines: [RemoteWorkspaceVoiceLine]
    public let message: String?

    public init(
        callID: UUID,
        workspaceID: UUID,
        phase: Phase,
        answerSDP: String? = nil,
        lines: [RemoteWorkspaceVoiceLine] = [],
        message: String? = nil
    ) {
        self.callID = callID
        self.workspaceID = workspaceID
        self.phase = phase
        self.answerSDP = answerSDP
        self.lines = lines
        self.message = message
    }
}
