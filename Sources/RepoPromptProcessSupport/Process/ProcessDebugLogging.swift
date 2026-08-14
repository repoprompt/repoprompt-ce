import Darwin
import Foundation

package enum ProcessDebugLogging {
    package static func log(
        prefix: String,
        _ message: @autoclosure () -> String,
        enabled: Bool = true,
        flushStdout: Bool = false
    ) {
        #if DEBUG
            guard enabled else { return }
            print("[\(prefix)] \(message())")
            if flushStdout {
                fflush(stdout)
            }
        #endif
    }
}
