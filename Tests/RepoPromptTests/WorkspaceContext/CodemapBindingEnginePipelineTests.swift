import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapBindingEnginePipelineTests: CodemapBindingEngineTestCase {
    func testOneRootServesMultipleLanguagePipelines() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature"),
                "Sources/Feature.ts": "export interface Feature {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        guard case .registered(adoptedReadyCount: 0) = await fixture.engine.registerRoot(fixture.registration) else {
            return XCTFail("Expected language-neutral registration.")
        }

        async let swiftResult = fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.swift", language: .swift)
        )
        async let typeScriptResult = fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.ts", language: .ts)
        )
        guard case .ready = await swiftResult,
              case .ready = await typeScriptResult
        else { return XCTFail("Expected both language pipelines to become ready.") }

        let bundleValue = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let bundle = try XCTUnwrap(bundleValue)
        XCTAssertEqual(Set(bundle.entries.map(\.standardizedRelativePath)), [
            "Sources/Feature.swift",
            "Sources/Feature.ts"
        ])
    }

    func testPipelineManifestsRemainDistinct() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature"),
                "Sources/Feature.ts": "export interface Feature {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard case .ready = await fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.swift", language: .swift)
        ), case .ready = await fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.ts", language: .ts)
        ) else { return XCTFail("Expected both pipeline manifests to be written.") }

        let capability = try await eligible(fixture.capabilityService.resolve(
            root: fixture.registration.capabilityRequest
        ))
        let swiftNamespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: SyntaxManager.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
        )
        let typeScriptNamespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: SyntaxManager.shared.pipelineIdentity(
                for: .ts,
                decoderPolicy: .workspaceAutomaticV1
            )
        )
        XCTAssertNotEqual(swiftNamespace.storageDigestHex, typeScriptNamespace.storageDigestHex)
        let swiftManifest = try await runtime.manifestStore.loadCurrentManifest(
            namespace: swiftNamespace,
            currentAuthority: CodeMapRootManifestAuthority(
                namespace: swiftNamespace,
                token: capability.repositoryAuthority
            )
        )
        let typeScriptManifest = try await runtime.manifestStore.loadCurrentManifest(
            namespace: typeScriptNamespace,
            currentAuthority: CodeMapRootManifestAuthority(
                namespace: typeScriptNamespace,
                token: capability.repositoryAuthority
            )
        )
        guard case let .hit(swiftSnapshot) = swiftManifest,
              case let .hit(typeScriptSnapshot) = typeScriptManifest
        else { return XCTFail("Expected distinct persisted pipeline manifests.") }
        XCTAssertEqual(swiftSnapshot.records.map(\.repositoryRelativePath), ["Sources/Feature.swift"])
        XCTAssertEqual(typeScriptSnapshot.records.map(\.repositoryRelativePath), ["Sources/Feature.ts"])
    }

    func testRootInvalidationRevokesEveryPipeline() async throws {
        let repository = try makeRepositoryFixture(name: #function)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature"),
                "Sources/Feature.ts": "export interface Feature {}\n"
            ]
        )
        let runtime = try CodeMapArtifactRuntime(
            rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
        )
        let fixture = try await makeEngineFixture(root: root, runtime: runtime)
        _ = await fixture.engine.registerRoot(fixture.registration)
        guard await isReady(fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.swift", language: .swift)
        )), await isReady(fixture.engine.demand(
            fixture.demand(path: "Sources/Feature.ts", language: .ts)
        )) else {
            return XCTFail("Expected both language pipelines to become ready before invalidation.")
        }
        let frozenBeforeInvalidation = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        let retainedBundle = try XCTUnwrap(frozenBeforeInvalidation)
        XCTAssertEqual(
            Set(retainedBundle.entries.map(\.standardizedRelativePath)),
            ["Sources/Feature.swift", "Sources/Feature.ts"]
        )
        retainedBundle.close()

        let result = await fixture.engine.invalidateRepositoryAuthority(rootEpoch: fixture.rootEpoch)
        XCTAssertFalse(result.manifestWriteFailed)
        let snapshotAfterInvalidation = await fixture.engine.snapshot(rootEpoch: fixture.rootEpoch)
        let revokedSnapshot = try XCTUnwrap(snapshotAfterInvalidation)
        XCTAssertFalse(revokedSnapshot.authorityIsCurrent)
        XCTAssertTrue(revokedSnapshot.entries.isEmpty)
        let bundle = await fixture.engine.freeze(rootEpoch: fixture.rootEpoch)
        XCTAssertNil(bundle)
        let accounting = await fixture.engine.accounting()
        XCTAssertEqual(accounting.dirtyManifestCount, 0)
    }
}
