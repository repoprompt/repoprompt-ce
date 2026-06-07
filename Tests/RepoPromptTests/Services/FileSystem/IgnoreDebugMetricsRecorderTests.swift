#if DEBUG
    @testable import RepoPrompt
    @testable import RepoPromptCore
    import XCTest

    final class IgnoreDebugMetricsRecorderTests: XCTestCase {
        override func tearDown() {
            IgnoreDebugMetricsRecorder.resetRecordingEnabledForTesting()
            super.tearDown()
        }

        func testMetricsAreDisabledWhenRecordingIsNotEnabled() {
            IgnoreDebugMetricsRecorder.setRecordingEnabledForTesting(false)

            let compiled = GitignoreCompiler.compile(content: """
            *.tmp
            !logs/keep.log
            """)
            _ = compiled.outcome(for: "scratch.tmp", isDirectory: false)
            _ = compiled.requiresTraversal(for: "logs")

            XCTAssertEqual(IgnoreDebugMetricsRecorder.snapshot(), IgnoreDebugMetrics())
        }

        func testMetricsRecordWhenExplicitlyEnabledAndCanResetAndSnapshot() {
            IgnoreDebugMetricsRecorder.setRecordingEnabledForTesting(true)

            let compiled = GitignoreCompiler.compile(content: """
            *.tmp
            !logs/keep.log
            """)
            var snapshot = IgnoreDebugMetricsRecorder.snapshot()
            XCTAssertEqual(snapshot.compileCallCount, 1)
            XCTAssertEqual(snapshot.compilePatternCount, 2)
            XCTAssertEqual(snapshot.compileNegationPatternCount, 1)

            _ = compiled.outcome(for: "scratch.tmp", isDirectory: false)
            snapshot = IgnoreDebugMetricsRecorder.snapshot()
            XCTAssertEqual(snapshot.outcomeEvaluationCount, 1)
            XCTAssertGreaterThan(snapshot.patternVisitCount, 0)

            IgnoreDebugMetricsRecorder.reset()
            XCTAssertEqual(IgnoreDebugMetricsRecorder.snapshot(), IgnoreDebugMetrics())

            let rules = IgnoreRules()
            rules.addIgnoreFile(content: "!logs/keep.log", priority: 0)
            IgnoreDebugMetricsRecorder.reset()

            XCTAssertTrue(rules.requiresTraversal(for: "logs"))
            snapshot = IgnoreDebugMetricsRecorder.snapshot()
            XCTAssertEqual(snapshot.traversalRequiresCheckCount, 1)
            XCTAssertGreaterThanOrEqual(snapshot.traversalExactPrefixHitCount + snapshot.traversalPatternHitCount, 1)
        }
    }
#endif
