import Foundation

package enum FileManagerError: Error, LocalizedError {
    case failedToLoadFolder(Error)
    case failedToLoadFile(Error)
    case fileSystemServiceNotFound
    case failedToLoadContent
    case fileSystemServiceNotFoundWithContext(String)

    package var errorDescription: String? {
        switch self {
        case let .failedToLoadFolder(error):
            "Failed to load folder: \(error.localizedDescription)"
        case let .failedToLoadFile(error):
            "Failed to load file: \(error.localizedDescription)"
        case .fileSystemServiceNotFound:
            "No matching workspace folder for the requested path."
        case .failedToLoadContent:
            "Failed to load content."
        case let .fileSystemServiceNotFoundWithContext(context):
            context
        }
    }
}
