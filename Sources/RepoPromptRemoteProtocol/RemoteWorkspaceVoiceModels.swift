import Foundation

/// Conversational V3 voices returned by the bundled Codex app-server.
public enum RemoteWorkspaceVoicePreset: String, CaseIterable, Codable, Sendable {
    case arbor, aube, breeze, bubbie, cove, ember, haetsal, hanul, himari, juniper, leher, maple
    case miko, neer, porto, rindo, rio, rivage, selva, sol, sonna, spruce, tinta, vale, viola

    public var displayName: String {
        rawValue.capitalized
    }
}

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
    public let voice: RemoteWorkspaceVoicePreset?

    public init(
        action: Action, callID: UUID, workspaceID: UUID, offerSDP: String? = nil,
        voice: RemoteWorkspaceVoicePreset? = nil
    ) {
        self.action = action
        self.callID = callID
        self.workspaceID = workspaceID
        self.offerSDP = offerSDP
        self.voice = voice
    }

    public var isValid: Bool {
        switch action {
        case .start:
            guard let offerSDP else { return false }
            return offerSDP.hasPrefix("v=0") && offerSDP.utf8.count <= 64 * 1024
        case .status, .end:
            return offerSDP == nil && voice == nil
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

public enum RemoteWorkspaceVoiceActivity: String, Codable, Sendable {
    case listening
    case thinking
    case speaking
    case findingChats
    case readingChat
    case checkingFiles
    case startingChat
    case sendingMessage
    case checkingSettings
    case changingSettings

    public var displayLabel: String {
        switch self {
        case .listening: "Listening"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        case .findingChats: "Finding chats…"
        case .readingChat: "Reading the chat…"
        case .checkingFiles: "Checking workspace files…"
        case .startingChat: "Starting the chat…"
        case .sendingMessage: "Sending the instruction…"
        case .checkingSettings: "Checking available settings…"
        case .changingSettings: "Changing settings…"
        }
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
    public let activity: RemoteWorkspaceVoiceActivity?
    public let workingChatID: UUID?

    public init(
        callID: UUID,
        workspaceID: UUID,
        phase: Phase,
        answerSDP: String? = nil,
        lines: [RemoteWorkspaceVoiceLine] = [],
        message: String? = nil,
        activity: RemoteWorkspaceVoiceActivity? = nil,
        workingChatID: UUID? = nil
    ) {
        self.callID = callID
        self.workspaceID = workspaceID
        self.phase = phase
        self.answerSDP = answerSDP
        self.lines = lines
        self.message = message
        self.activity = activity
        self.workingChatID = workingChatID
    }
}
