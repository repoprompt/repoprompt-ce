import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
enum CanonicalSavedWorkspaceFixture {
    static func run(
        _ workspace: WorkspaceModel, perform: (WorkspaceModel) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanonicalSavedWorkspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app, profileIdentifier: "canonical-saved-\(UUID())", storageDirectory: directory,
            workspaceStorageDirectory: directory.appendingPathComponent("workspaces"),
            eventDirectory: directory.appendingPathComponent("events"), temporaryDirectory: directory.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        do {
            let authority = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: 101)
            var canonical = workspace
            canonical.isEphemeral = false
            canonical.customStoragePath = workspace.customStoragePath ?? directory.appendingPathComponent("sessions")
            let created = try await authority.create(canonical, fileURL: directory.appendingPathComponent("workspace.json"))
            guard created.disposition == .applied else {
                XCTFail("Expected canonical workspace fixture placement: \(created.diagnostic ?? created.disposition.rawValue)")
                throw CocoaError(.fileWriteUnknown)
            }
            try await AppDomainRuntimeComposition.shared.withRuntimeForTesting(runtime) { try await perform(canonical) }
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
        _ = await runtime.shutdown()
    }
}
