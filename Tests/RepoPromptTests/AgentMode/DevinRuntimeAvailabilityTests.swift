import Foundation
@testable import RepoPromptApp
import XCTest

/// Devin has no RepoPrompt-owned connect step: the installed `devin` executable is the
/// connection. These cover the probe that decides that, and the selection surfaces it feeds.
final class DevinRuntimeAvailabilityTests: XCTestCase {
    // MARK: - Installed-runtime probe

    func testResolvesAnExecutableDevinOnThePath() throws {
        let directory = try makeTestDirectory(name: "DevinRuntimeLocatorInstalled")
        let executable = try makeDevinExecutable(in: directory)

        XCTAssertEqual(
            DevinRuntimeLocator.installedCommand(
                environment: ["PATH": directory.path],
                additionalPathHints: []
            ),
            executable.path
        )
    }

    func testResolvesDevinFromAProviderPathHintWhenPathMisses() throws {
        let directory = try makeTestDirectory(name: "DevinRuntimeLocatorHint")
        let executable = try makeDevinExecutable(in: directory)

        XCTAssertEqual(
            DevinRuntimeLocator.installedCommand(
                environment: ["PATH": "/nonexistent-devin-search-path"],
                additionalPathHints: [directory.path]
            ),
            executable.path
        )
    }

    func testReportsNotInstalledWhenNothingResolves() {
        XCTAssertNil(
            DevinRuntimeLocator.installedCommand(
                environment: ["PATH": "/nonexistent-devin-search-path"],
                additionalPathHints: []
            )
        )
        XCTAssertNil(
            DevinRuntimeLocator.installedCommand(environment: [:], additionalPathHints: [])
        )
    }

    func testRejectsANonExecutableOrDirectoryNamedDevin() throws {
        let nonExecutableRoot = try makeTestDirectory(name: "DevinRuntimeLocatorNonExecutable")
        try "not runnable".write(
            to: nonExecutableRoot.appendingPathComponent("devin"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertNil(
            DevinRuntimeLocator.installedCommand(
                environment: ["PATH": nonExecutableRoot.path],
                additionalPathHints: []
            )
        )

        let directoryRoot = try makeTestDirectory(name: "DevinRuntimeLocatorDirectory")
        try FileManager.default.createDirectory(
            at: directoryRoot.appendingPathComponent("devin", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertNil(
            DevinRuntimeLocator.installedCommand(
                environment: ["PATH": directoryRoot.path],
                additionalPathHints: []
            )
        )
    }

    // MARK: - Selection surfaces

    func testInstalledDevinIsSelectableInTheGeneralSurface() {
        let agents = AgentModelCatalog.selectableAgents(
            availability: availability(devinInstalled: true),
            surface: .general
        )
        XCTAssertTrue(agents.contains(.devin))
    }

    func testUninstalledDevinIsNotSelectable() {
        let agents = AgentModelCatalog.selectableAgents(
            availability: availability(devinInstalled: false),
            surface: .general
        )
        XCTAssertFalse(agents.contains(.devin))
    }

    func testInstalledDevinIsStillExcludedFromTheHeadlessSurface() {
        // Headless/Context Builder runs get `UnsupportedHeadlessAgentProvider` for Devin,
        // so installation must not make it offerable there.
        let agents = AgentModelCatalog.selectableAgents(
            availability: availability(devinInstalled: true),
            surface: .headless
        )
        XCTAssertFalse(agents.contains(.devin))
        XCTAssertFalse(AgentModelCatalog.AgentSelectionSurface.headless.allows(.devin))
        XCTAssertTrue(AgentModelCatalog.AgentSelectionSurface.general.allows(.devin))
    }

    func testAgentAvailabilityAndCapabilitySummaryFollowTheInstalledFlag() {
        XCTAssertTrue(
            AgentModelCatalog.isAgentAvailable(.devin, availability: availability(devinInstalled: true))
        )
        XCTAssertFalse(
            AgentModelCatalog.isAgentAvailable(.devin, availability: availability(devinInstalled: false))
        )
        XCTAssertTrue(
            AgentPermissionCapabilitySummaryBuilder.isAvailable(
                providerID: .devin,
                availability: availability(devinInstalled: true)
            )
        )
        XCTAssertFalse(
            AgentPermissionCapabilitySummaryBuilder.isAvailable(
                providerID: .devin,
                availability: availability(devinInstalled: false)
            )
        )
    }

    // MARK: - Helpers

    private func availability(devinInstalled: Bool) -> AgentModelCatalog.AvailabilityContext {
        AgentModelCatalog.AvailabilityContext(devinAvailable: devinInstalled)
    }

    private func makeDevinExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
