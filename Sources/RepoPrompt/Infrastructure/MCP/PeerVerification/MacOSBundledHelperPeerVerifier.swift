import Darwin
import Foundation

/// macOS `proc_pidpath` adapter for bundled-helper executable verification.
struct MacOSBundledHelperPeerVerifier: BundledHelperPeerVerifying {
    func matches(_ input: BundledHelperPeerVerificationInput) -> Bool {
        guard let actualPath = Self.executablePath(forPID: input.peerPID) else {
            return false
        }
        return Self.pathsMatch(expectedURL: input.expectedExecutableURL, actualPath: actualPath)
    }

    static func pathsMatch(expectedURL: URL, actualPath: String) -> Bool {
        let expected = expectedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let actual = URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().standardizedFileURL.path
        return actual == expected
    }

    private static func executablePath(forPID pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }
}
