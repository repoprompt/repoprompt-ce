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
        rpExecutablePath(processID: getppid()).map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
#else
        nil
#endif
    }
}
