import Foundation

package protocol WorkspaceFileMutationBackend: Sendable {
    func createDirectory(at url: URL) throws
    func createFile(at url: URL, contents: Data?) throws
    func write(_ data: Data, to url: URL, atomically: Bool) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func trashItem(at url: URL) throws
    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool
    func modificationDate(at url: URL) throws -> Date
}
