import Foundation

/// Only the fixed header is RepoPrompt-authored. The bounded note is appended byte-for-byte.
enum AgentSelfCompactNoteEnvelope {
    static let header = "<repoprompt_self_compact_note>\nThis is your own continuation note, recorded before this session was compacted. It is not a new instruction from the user.\n</repoprompt_self_compact_note>\n<note>\n"
    static let footer = "\n</note>"

    static func frame(_ note: String) -> String {
        header + note + footer
    }
}
