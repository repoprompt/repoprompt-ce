import Foundation

public protocol FileEditHost {
    func fileExists(path: String) async -> Bool
    func readText(path: String) async throws -> String
    func writeText(path: String, content: String, overwrite: Bool) async throws
}
