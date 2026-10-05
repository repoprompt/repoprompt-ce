import Foundation

public enum GitDiffPublishMode: String, Codable, Sendable {
    case quick
    case standard
    case deep
}
