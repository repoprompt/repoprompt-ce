import Foundation
@testable import RepoPromptProcess
import XCTest

final class CLIProcessRunnerCapturedOutputTests: XCTestCase {
    func testRunReturnsAllOutputWhenReadersStartAfterChildExit() async throws {
        let readers = DispatchSemaphore(value: 0)
        let runner = CLIProcessRunner(
            config: CLIProcessConfiguration(command: "/bin/sh", processPurpose: .tool, enableDebugLogging: false),
            beforeOutputRead: { readers.wait() },
            beforeOutputDrain: {
                readers.signal()
                readers.signal()
            }
        )
        addTeardownBlock {
            readers.signal()
            readers.signal()
            await runner.cancelAll()
        }

        let result = try await runner.run(
            args: ["-c", "printf 'stdout-before-exit\\n'; printf 'stderr-before-exit\\n' >&2"],
            stdin: nil,
            outputMode: .none,
            timeout: 2
        )

        XCTAssertEqual(result.stdout, Data("stdout-before-exit\n".utf8))
        XCTAssertEqual(result.stderr, Data("stderr-before-exit\n".utf8))
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
    }
}
