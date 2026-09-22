import Foundation
import XCTest

/// This is a deliberately small lexical guard for the two lock owners that run
/// caller-supplied closures. It is not a general Swift parser: its scope is the
/// reviewed authority-mirror and accepted-watermark implementations below.
final class GitWorkspaceAuthorityLockReentryGuardTests: XCTestCase {
    func testReviewedLockOwnersUseSameThreadReentryCheckedLocks() throws {
        let root = try RepoRoot.url()
        let authoritySource = try Self.source(
            at: "Sources/RepoPrompt/Infrastructure/VCS/GitWorkspaceStateAuthority.swift",
            root: root
        )
        let watermarksSource = try Self.source(
            at: "Sources/RepoPrompt/Infrastructure/VCS/GitWorkspaceMetadataMonitor.swift",
            root: root
        )
        let authority = try Self.typeSource(named: "GitWorkspaceAuthoritySynchronousState", in: authoritySource)
        let watermarks = try Self.typeSource(named: "GitMetadataAcceptedWatermarks", in: watermarksSource)

        for (name, source) in [("authority mirror", authority), ("accepted watermarks", watermarks)] {
            XCTAssertTrue(source.contains("SameThreadReentryCheckedLock()"), "\(name) lost its DEBUG reentry guard")
            XCTAssertFalse(source.contains("NSLock()"), "\(name) bypasses its DEBUG reentry guard")
        }
    }

    func testClosureInvocationsInReviewedLockOwnersCarryExplicitMarker() throws {
        let root = try RepoRoot.url()
        let authoritySource = try Self.source(
            at: "Sources/RepoPrompt/Infrastructure/VCS/GitWorkspaceStateAuthority.swift",
            root: root
        )
        let watermarksSource = try Self.source(
            at: "Sources/RepoPrompt/Infrastructure/VCS/GitWorkspaceMetadataMonitor.swift",
            root: root
        )
        let authority = try Self.typeSource(named: "GitWorkspaceAuthoritySynchronousState", in: authoritySource)
        let watermarks = try Self.typeSource(named: "GitMetadataAcceptedWatermarks", in: watermarksSource)

        XCTAssertEqual(Self.reentrancyMarkerViolations(in: authority), [])
        XCTAssertEqual(Self.reentrancyMarkerViolations(in: watermarks), [])
        XCTAssertEqual(Self.directClosureInvocationCount(in: authority), 1)
        XCTAssertEqual(Self.directClosureInvocationCount(in: watermarks), 2)
    }

    func testLexicalGuardDetectsRenamedUnreviewedCallback() {
        let reviewed = """
        private final class ReviewedOwner {
            func invoke(_ operation: () -> Void) {
                // REENTRANCY-REVIEWED: `operation` cannot synchronously re-enter this lock.
                operation()
            }
        }
        """
        let unreviewed = """
        private final class UnreviewedOwner {
            func invoke(callback: () -> Void) {
                callback()
            }
        }
        """

        XCTAssertEqual(Self.reentrancyMarkerViolations(in: reviewed), [])
        XCTAssertEqual(Self.reentrancyMarkerViolations(in: unreviewed), ["callback()"])
    }

    func testInstallAndPublicationPermitKeepMonitorBeforeAuthorityMirrorOrder() throws {
        let root = try RepoRoot.url()
        let authoritySource = try Self.source(
            at: "Sources/RepoPrompt/Infrastructure/VCS/GitWorkspaceStateAuthority.swift",
            root: root
        )
        let authority = try Self.typeSource(named: "GitWorkspaceStateAuthority", in: authoritySource)
        let install = try XCTUnwrap(
            Self.functionBodies(named: "install", in: authority)
                .first(where: { $0.contains("capturedUsing token") })
        )
        let permit = try XCTUnwrap(
            Self.functionBodies(named: "withPendingInitializationAuthorityPublicationPermit", in: authority).first
        )

        try Self.assertOrder(
            "metadataMonitor.withCurrentAcceptedWatermark",
            before: "updateSynchronousState(",
            in: install
        )
        try Self.assertOrder(
            "metadataMonitor.withCurrentAcceptedWatermarks",
            before: "synchronousState.withCurrentFences",
            in: permit
        )
    }

    private static func source(at relativePath: String, root: URL) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func typeSource(named name: String, in source: String) throws -> String {
        let typePrefixes = ["private final class \(name)", "actor \(name)"]
        guard let declaration = typePrefixes.lazy.compactMap({ source.range(of: $0) }).first
        else { throw GuardFailure.missingType(name) }
        guard let openingBrace = source[declaration.lowerBound...].firstIndex(of: "{")
        else { throw GuardFailure.missingOpeningBrace(name) }
        let closingBrace = try matchingBrace(after: openingBrace, in: source)
        return String(source[declaration.lowerBound ... closingBrace])
    }

    private static func functionBodies(named name: String, in source: String) -> [String] {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?m)^\s*(?:nonisolated\s+)?func\s+\#(escapedName)(?:<[^>]+>)?\s*\("#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard let declaration = Range(match.range, in: source),
                  let openingBrace = source[declaration.upperBound...].firstIndex(of: "{")
            else { return nil }
            guard let closingBrace = try? matchingBrace(after: openingBrace, in: source) else { return nil }
            return String(source[declaration.lowerBound ... closingBrace])
        }
    }

    private static func reentrancyMarkerViolations(in source: String) -> [String] {
        closureParameterNames(in: source).flatMap { name in
            directClosureInvocations(named: name, in: source).compactMap { invocation in
                previousNonemptyLine(before: invocation.lowerBound, in: source)?
                    .contains("// REENTRANCY-REVIEWED:") == true ? nil : "\(name)()"
            }
        }
    }

    private static func directClosureInvocationCount(in source: String) -> Int {
        closureParameterNames(in: source).reduce(0) { count, name in
            count + directClosureInvocations(named: name, in: source).count
        }
    }

    private static func closureParameterNames(in source: String) -> [String] {
        let pattern = #"(?:(?:_|[A-Za-z_][A-Za-z0-9_]*)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:@(?:escaping|Sendable)\s+)*\([^)]*\)\s*(?:async\s+)?(?:throws\s+)?->"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        let names = expression.matches(in: source, range: range).compactMap { match -> String? in
            guard let nameRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[nameRange])
        }
        return Array(Set(names)).sorted()
    }

    private static func directClosureInvocations(named name: String, in source: String) -> [Range<String.Index>] {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(pattern: "\\b\(escapedName)\\s*\\(") else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap { Range($0.range, in: source) }
    }

    private static func previousNonemptyLine(before index: String.Index, in source: String) -> Substring? {
        let lineStart = source[..<index].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        return source[..<lineStart]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func matchingBrace(after openingBrace: String.Index, in source: String) throws -> String.Index {
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = source.index(after: index)
        }
        throw GuardFailure.unclosedBrace
    }

    private static func assertOrder(
        _ first: String,
        before second: String,
        in source: String
    ) throws {
        let firstIndex = try XCTUnwrap(source.range(of: first)?.lowerBound)
        let secondIndex = try XCTUnwrap(source.range(of: second)?.lowerBound)
        XCTAssertLessThan(firstIndex, secondIndex, "expected \(first) before \(second)")
    }

    private enum GuardFailure: Error {
        case missingType(String)
        case missingOpeningBrace(String)
        case unclosedBrace
    }
}
