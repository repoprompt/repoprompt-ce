import Darwin
import Foundation

enum HeadlessTestTemporaryDirectory {
    static var baseURL: URL {
        let path = FileManager.default.temporaryDirectory.path
        return path.withCString { pointer in
            guard let resolved = Darwin.realpath(pointer, nil) else {
                return FileManager.default.temporaryDirectory
            }
            defer { Darwin.free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }
}
