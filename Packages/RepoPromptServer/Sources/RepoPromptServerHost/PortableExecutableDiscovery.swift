import Foundation

enum PortableExecutableDiscovery {
    static func resolve(named command: String, path: String?) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        let searchPaths = path?.split(separator: ":", omittingEmptySubsequences: true).map(String.init) ?? []
        return searchPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
            .first(where: FileManager.default.isExecutableFile)
    }
}
