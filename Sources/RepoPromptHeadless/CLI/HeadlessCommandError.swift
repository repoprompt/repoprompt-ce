import Foundation

struct HeadlessCommandError: LocalizedError {
    let message: String
    let exitCode: Int

    init(_ message: String, exitCode: Int = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    var errorDescription: String? {
        message
    }
}
