import RepoPromptRegexCore
import XCTest

final class PCRE2ConcurrencyTests: XCTestCase {
    func testOneCompiledRegexMatchesConcurrentlyWithIndependentState() async throws {
        let regex = try PCRE2Regex(#"^item-(\d+)$"#, jit: .disabled)
        let iterations = 256

        let results = try await withThrowingTaskGroup(
            of: Bool.self,
            returning: [Bool].self
        ) { group in
            for index in 0..<iterations {
                group.addTask {
                    let subject = "item-\(index)"
                    guard let match = try regex.firstMatch(in: subject) else {
                        return false
                    }
                    return match.byteRange == 0..<subject.utf8.count
                        && match.captureByteRanges[1] == 5..<subject.utf8.count
                }
            }

            var collected: [Bool] = []
            collected.reserveCapacity(iterations)
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, iterations)
        XCTAssertTrue(results.allSatisfy { $0 })
    }
}
