import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexManagedInstructionsProjectionTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    private var root: URL!
    private var ordinaryHome: URL!
    private var managedHome: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexManagedInstructionsProjectionTests-\(UUID().uuidString)")
        ordinaryHome = root.appendingPathComponent("ordinary")
        managedHome = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: ordinaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOverrideWinsAndProjectionIsARegularFile() throws {
        try write("fallback", to: ordinaryHome.appendingPathComponent("AGENTS.md"))
        let source = ordinaryHome.appendingPathComponent("AGENTS.override.md")
        try write("override", to: source)

        let state = try project()

        XCTAssertEqual(
            state,
            .projected(source: source, target: managedHome.appendingPathComponent("AGENTS.override.md"))
        )
        XCTAssertEqual(try read(managedHome.appendingPathComponent("AGENTS.override.md")), "override")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: managedHome.appendingPathComponent("AGENTS.override.md").path
        )
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedHome.appendingPathComponent("AGENTS.md").path))
    }

    func testForeignManagedFileIsPreservedAndReported() throws {
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        let target = managedHome.appendingPathComponent("AGENTS.md")
        try write("foreign", to: target)
        try write("ordinary", to: ordinaryHome.appendingPathComponent("AGENTS.md"))

        XCTAssertThrowsError(try project())
        XCTAssertEqual(try read(target), "foreign")
        XCTAssertEqual(
            CodexManagedInstructionsProjection.diagnostic(
                managedHome: managedHome,
                ordinaryHome: ordinaryHome
            ).status,
            .conflict
        )
    }

    func testModifiedProjectionAndSidecarArePreservedAndFailClosed() throws {
        let source = ordinaryHome.appendingPathComponent("AGENTS.md")
        try write("first", to: source)
        _ = try project()
        let target = managedHome.appendingPathComponent("AGENTS.md")
        try write("user edit", to: target)
        try write("second", to: source)

        XCTAssertThrowsError(try project())
        XCTAssertEqual(try read(target), "user edit")

        try write("first", to: target)
        let sidecar = managedHome.appendingPathComponent(
            CodexManagedInstructionsProjection.sidecarName
        )
        try write("foreign receipt", to: sidecar)
        XCTAssertThrowsError(try project())
        XCTAssertEqual(try read(target), "first")
        XCTAssertEqual(try read(sidecar), "foreign receipt")
    }

    func testOwnedProjectionIsRemovedWhenOrdinarySourceDisappears() throws {
        let source = ordinaryHome.appendingPathComponent("AGENTS.md")
        try write("ordinary", to: source)
        _ = try project()
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(try project(), .absent(managedHome: managedHome))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedHome.appendingPathComponent("AGENTS.md").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: managedHome.appendingPathComponent(
                    CodexManagedInstructionsProjection.sidecarName
                ).path
            )
        )
    }

    func testSymlinkSourceTargetSidecarAndManagedAncestorAreRejectedWithoutFollowingThem() throws {
        let externalSource = root.appendingPathComponent("external-source")
        try write("external", to: externalSource)
        let sourceLink = ordinaryHome.appendingPathComponent("AGENTS.md")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: externalSource)
        XCTAssertThrowsError(try project())
        XCTAssertEqual(try read(externalSource), "external")
        try FileManager.default.removeItem(at: sourceLink)

        let externalOrdinaryHome = root.appendingPathComponent("external-ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: externalOrdinaryHome, withIntermediateDirectories: true)
        try write("ancestor source", to: externalOrdinaryHome.appendingPathComponent("AGENTS.md"))
        let ordinaryHomeLink = root.appendingPathComponent("ordinary-link")
        try FileManager.default.createSymbolicLink(
            at: ordinaryHomeLink,
            withDestinationURL: externalOrdinaryHome
        )
        XCTAssertThrowsError(
            try CodexManagedInstructionsProjection.projectBeforeLaunch(
                managedHome: managedHome,
                ordinaryHome: ordinaryHomeLink
            )
        )
        XCTAssertEqual(
            try read(externalOrdinaryHome.appendingPathComponent("AGENTS.md")),
            "ancestor source"
        )

        try write("ordinary", to: ordinaryHome.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        let externalTarget = root.appendingPathComponent("external-target")
        try write("preserve target", to: externalTarget)
        let targetLink = managedHome.appendingPathComponent("AGENTS.md")
        try FileManager.default.createSymbolicLink(at: targetLink, withDestinationURL: externalTarget)
        XCTAssertThrowsError(try project())
        XCTAssertEqual(try read(externalTarget), "preserve target")
        try FileManager.default.removeItem(at: targetLink)

        _ = try project()
        let target = managedHome.appendingPathComponent("AGENTS.md")
        let sidecar = managedHome.appendingPathComponent(
            CodexManagedInstructionsProjection.sidecarName
        )
        let externalSidecar = root.appendingPathComponent("external-sidecar")
        try write("preserve sidecar", to: externalSidecar)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: externalSidecar)
        XCTAssertThrowsError(try project())
        XCTAssertEqual(try read(target), "ordinary")
        XCTAssertEqual(try read(externalSidecar), "preserve sidecar")

        let externalDirectory = root.appendingPathComponent("external-directory")
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let linkedParent = root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: externalDirectory)
        XCTAssertThrowsError(
            try CodexManagedInstructionsProjection.projectBeforeLaunch(
                managedHome: linkedParent.appendingPathComponent("managed"),
                ordinaryHome: ordinaryHome
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent("managed").path))
        XCTAssertEqual(
            CodexManagedInstructionsProjection.diagnostic(
                managedHome: linkedParent.appendingPathComponent("managed"),
                ordinaryHome: ordinaryHome
            ).status,
            .conflict
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent("managed").path))
    }

    func testInterruptedSourceSwitchPreservesLastKnownGoodAndRecoversDeterministically() throws {
        let fallbackSource = ordinaryHome.appendingPathComponent("AGENTS.md")
        try write("fallback", to: fallbackSource)
        _ = try project()
        let fallbackTarget = managedHome.appendingPathComponent("AGENTS.md")
        try write("override", to: ordinaryHome.appendingPathComponent("AGENTS.override.md"))

        XCTAssertThrowsError(
            try project { checkpoint in
                if checkpoint == .afterPendingReceipt { throw InjectedFailure.stop }
            }
        )
        XCTAssertEqual(try read(fallbackTarget), "fallback")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: managedHome.appendingPathComponent("AGENTS.override.md").path
            )
        )
        XCTAssertEqual(
            CodexManagedInstructionsProjection.diagnostic(
                managedHome: managedHome,
                ordinaryHome: ordinaryHome
            ).status,
            .conflict
        )

        _ = try project()
        XCTAssertEqual(try read(managedHome.appendingPathComponent("AGENTS.override.md")), "override")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackTarget.path))
    }

    func testInterruptedSwitchAfterNewTargetWriteRecoversWithoutStaleFallback() throws {
        try write("fallback", to: ordinaryHome.appendingPathComponent("AGENTS.md"))
        _ = try project()
        try write("override", to: ordinaryHome.appendingPathComponent("AGENTS.override.md"))

        XCTAssertThrowsError(
            try project { checkpoint in
                if checkpoint == .afterTargetWrite { throw InjectedFailure.stop }
            }
        )
        XCTAssertEqual(try read(managedHome.appendingPathComponent("AGENTS.md")), "fallback")
        XCTAssertEqual(try read(managedHome.appendingPathComponent("AGENTS.override.md")), "override")

        _ = try project()
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedHome.appendingPathComponent("AGENTS.md").path))
        XCTAssertEqual(try read(managedHome.appendingPathComponent("AGENTS.override.md")), "override")
        XCTAssertEqual(
            CodexManagedInstructionsProjection.diagnostic(
                managedHome: managedHome,
                ordinaryHome: ordinaryHome
            ).status,
            .current(sourceName: "AGENTS.override.md")
        )
    }

    func testInterruptedSwitchAfterPreviousRemovalCommitsNewProjectionOnRecovery() throws {
        try write("fallback", to: ordinaryHome.appendingPathComponent("AGENTS.md"))
        _ = try project()
        try write("override", to: ordinaryHome.appendingPathComponent("AGENTS.override.md"))

        XCTAssertThrowsError(
            try project { checkpoint in
                if checkpoint == .afterPreviousTargetRemoval { throw InjectedFailure.stop }
            }
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedHome.appendingPathComponent("AGENTS.md").path))
        XCTAssertEqual(try read(managedHome.appendingPathComponent("AGENTS.override.md")), "override")

        _ = try project()
        XCTAssertEqual(
            CodexManagedInstructionsProjection.diagnostic(
                managedHome: managedHome,
                ordinaryHome: ordinaryHome
            ).status,
            .current(sourceName: "AGENTS.override.md")
        )
    }

    func testInterruptedOwnedRemovalFinishesWithoutPermanentConflict() throws {
        let source = ordinaryHome.appendingPathComponent("AGENTS.md")
        try write("ordinary", to: source)
        _ = try project()
        try FileManager.default.removeItem(at: source)

        XCTAssertThrowsError(
            try project { checkpoint in
                if checkpoint == .afterOwnedTargetRemoval { throw InjectedFailure.stop }
            }
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedHome.appendingPathComponent("AGENTS.md").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: managedHome.appendingPathComponent(
                    CodexManagedInstructionsProjection.sidecarName
                ).path
            )
        )

        XCTAssertEqual(try project(), .absent(managedHome: managedHome))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: managedHome.appendingPathComponent(
                    CodexManagedInstructionsProjection.sidecarName
                ).path
            )
        )
    }

    func testSourceSwitchDetectsForeignNewTargetBeforeRemovingOwnedProjection() throws {
        try write("fallback", to: ordinaryHome.appendingPathComponent("AGENTS.md"))
        _ = try project()
        let fallbackTarget = managedHome.appendingPathComponent("AGENTS.md")
        let overrideTarget = managedHome.appendingPathComponent("AGENTS.override.md")
        try write("foreign override", to: overrideTarget)
        try write("ordinary override", to: ordinaryHome.appendingPathComponent("AGENTS.override.md"))

        XCTAssertThrowsError(try project())
        XCTAssertEqual(try read(fallbackTarget), "fallback")
        XCTAssertEqual(try read(overrideTarget), "foreign override")
    }

    func testDiagnosticsCoverAbsentCurrentConflictAndErrorWithoutSourceContents() throws {
        var diagnostic = CodexManagedInstructionsProjection.diagnostic(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome
        )
        XCTAssertEqual(diagnostic.status, .absent)

        let secretMarker = "do-not-leak-secret-instruction"
        try write(secretMarker, to: ordinaryHome.appendingPathComponent("AGENTS.md"))
        diagnostic = CodexManagedInstructionsProjection.diagnostic(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome
        )
        XCTAssertEqual(diagnostic.status, .absent)
        XCTAssertFalse(diagnostic.message.contains(secretMarker))

        _ = try project()
        diagnostic = CodexManagedInstructionsProjection.diagnostic(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome
        )
        XCTAssertEqual(diagnostic.status, .current(sourceName: "AGENTS.md"))
        XCTAssertFalse(diagnostic.message.contains(secretMarker))

        try write("modified", to: managedHome.appendingPathComponent("AGENTS.md"))
        diagnostic = CodexManagedInstructionsProjection.diagnostic(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome
        )
        XCTAssertEqual(diagnostic.status, .conflict)
        XCTAssertFalse(diagnostic.message.contains(secretMarker))

        diagnostic = CodexManagedInstructionsProjection.diagnostic(
            for: CocoaError(.fileReadNoPermission)
        )
        XCTAssertEqual(diagnostic.status, .error)
        XCTAssertFalse(diagnostic.message.contains(secretMarker))
    }

    @discardableResult
    private func project(
        checkpoint: ((CodexManagedInstructionsProjection.MutationCheckpoint) throws -> Void)? = nil
    ) throws -> CodexManagedInstructionsProjection.State {
        try CodexManagedInstructionsProjection.projectBeforeLaunch(
            managedHome: managedHome,
            ordinaryHome: ordinaryHome,
            checkpoint: checkpoint
        )
    }

    private func write(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
