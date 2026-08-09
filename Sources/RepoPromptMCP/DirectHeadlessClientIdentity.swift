import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum DirectHeadlessClientIdentity {
    static func detectParentExecutableName() -> String? {
#if canImport(Darwin)
        CLIEventLogger.detectClientName()
#elseif canImport(Glibc)
        let link = "/proc/\(getppid())/exe"
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(link, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[Int(count)] = 0
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
#else
        nil
#endif
    }
}
