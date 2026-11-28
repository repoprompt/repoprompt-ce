import Combine
import Foundation
import os
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class DeferredAgentModelsProfileSaveTests: XCTestCase {
    func testSlowWriteLeavesMainActorFreeAndLatestEditSurvivesQuitSettlement() async throws {
        let url = try makeSettingsURL()
        let firstWriteStarted = expectation(description: "first profile snapshot reached the writer")
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        defer { releaseFirstWrite.signal() }
        let store = GlobalSettingsStore(fileStore: GlobalSettingsFileStore(fileURL: url, atomicWriter: { data, url in
            if data.range(of: Data("first edit".utf8)) != nil {
                XCTAssertFalse(Thread.isMainThread)
                firstWriteStarted.fulfill()
                guard releaseFirstWrite.wait(timeout: .now() + 10) == .success else {
                    XCTFail("The main actor did not release the paused writer")
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try data.write(to: url, options: .atomic)
        }))
        let initialBytes = try Data(contentsOf: url)

        XCTAssertTrue(apply("first edit", to: store))
        await fulfillment(of: [firstWriteStarted], timeout: 5)
        XCTAssertEqual(store.globalAgentModelsProfile().oracleReconciliationGuidance, "first edit")
        XCTAssertTrue(apply("second edit", to: store))
        XCTAssertEqual(store.globalAgentModelsProfile().oracleReconciliationGuidance, "second edit")
        XCTAssertEqual(try Data(contentsOf: url), initialBytes)
        XCTAssertNil(store.reloadFontScaleBodySizeFromDisk(normalize: { $0 }))
        store.freezeDeferredProfileSavesForTermination()
        XCTAssertFalse(apply("late edit", to: store))
        releaseFirstWrite.signal()

        await store.settleDeferredProfileSavesForTermination()
        XCTAssertNil(store.persistenceBlockReason)
        let onDisk = try GlobalSettingsFileStore(fileURL: url).load()
        XCTAssertEqual(onDisk.scalarPreferences?.modelSelection?.oracleReconciliationGuidance, "second edit")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(raw["fixtureFutureField"] as? String, "keep me")
    }

    func testFailedDeferredWritePublishesBlockAndRetryKeepsTheLiveEdit() async throws {
        let url = try makeSettingsURL()
        let rejectWrites = OSAllocatedUnfairLock(initialState: false)
        let store = GlobalSettingsStore(fileStore: GlobalSettingsFileStore(fileURL: url, atomicWriter: { data, url in
            if rejectWrites.withLock({ $0 }) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }))
        let initialBytes = try Data(contentsOf: url)
        rejectWrites.withLock { $0 = true }
        let failed = expectation(description: "deferred failure reached the main actor")
        let observation = store.$persistenceBlockReason.sink { reason in
            if reason == .saveFailed {
                failed.fulfill()
            }
        }
        defer { observation.cancel() }

        XCTAssertTrue(apply("keep this edit", to: store))
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(store.persistenceBlockReason, .saveFailed)
        XCTAssertEqual(try Data(contentsOf: url), initialBytes)
        XCTAssertEqual(store.globalAgentModelsProfile().oracleReconciliationGuidance, "keep this edit")

        rejectWrites.withLock { $0 = false }
        XCTAssertTrue(store.retryBlockedPersistenceSave())
        XCTAssertNil(store.persistenceBlockReason)
        let onDisk = try GlobalSettingsFileStore(fileURL: url).load()
        XCTAssertEqual(onDisk.scalarPreferences?.modelSelection?.oracleReconciliationGuidance, "keep this edit")
    }

    func testDeferredWriteRefusesAnExternalGeneration() async throws {
        let url = try makeSettingsURL()
        let store = GlobalSettingsStore(fileStore: GlobalSettingsFileStore(fileURL: url))
        let externalStore = GlobalSettingsStore(fileStore: GlobalSettingsFileStore(fileURL: url))
        externalStore.setAppearanceModeRaw("Dark")
        let externalBytes = try Data(contentsOf: url)

        XCTAssertTrue(apply("stale edit", to: store))
        store.freezeDeferredProfileSavesForTermination()
        await store.settleDeferredProfileSavesForTermination()
        XCTAssertEqual(store.persistenceBlockReason, .changedOnDisk)
        XCTAssertFalse(store.retryBlockedPersistenceSave())
        XCTAssertEqual(try Data(contentsOf: url), externalBytes)
    }

    func testEncodingFailureBeforeAtomicWriteStillPublishesSaveFailure() async throws {
        let url = try makeSettingsURL()
        let store = GlobalSettingsStore(fileStore: GlobalSettingsFileStore(fileURL: url))
        let initialBytes = try Data(contentsOf: url)
        store.setModelTemperature(.infinity, commit: false)

        XCTAssertTrue(apply("unencodable snapshot", to: store))
        store.freezeDeferredProfileSavesForTermination()
        await store.settleDeferredProfileSavesForTermination()
        XCTAssertEqual(store.persistenceBlockReason, .saveFailed)
        XCTAssertEqual(try Data(contentsOf: url), initialBytes)
    }

    func testRecoveryAfterQueuedSaveClearsFailurePreservesUnknownFields() throws {
        let url = try makeSettingsURL()
        let rejectWrites = OSAllocatedUnfairLock(initialState: false)
        let store = GlobalSettingsStore(fileStore: GlobalSettingsFileStore(fileURL: url, atomicWriter: { data, url in
            if rejectWrites.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }))
        rejectWrites.withLock { $0 = true }
        store.setAppearanceModeRaw("Dark")
        XCTAssertEqual(store.persistenceBlockReason, .saveFailed)
        rejectWrites.withLock { $0 = false }

        XCTAssertTrue(apply("queued save", to: store))
        XCTAssertTrue(store.recoverBlockedPersistenceAfterBackup())
        XCTAssertNil(store.persistenceBlockReason)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(raw["fixtureFutureField"] as? String, "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Backups").path))
    }

    func testSynchronousSaveCommitsAfterQueuedProfileSnapshot() throws {
        let url = try makeSettingsURL()
        let store = GlobalSettingsStore(fileStore: GlobalSettingsFileStore(fileURL: url))
        XCTAssertTrue(apply("profile edit", to: store))
        store.setAppearanceModeRaw("Dark")

        let onDisk = try GlobalSettingsFileStore(fileURL: url).load()
        XCTAssertEqual(onDisk.scalarPreferences?.modelSelection?.oracleReconciliationGuidance, "profile edit")
        XCTAssertEqual(onDisk.scalarPreferences?.ui?.appearanceMode, "Dark")
    }

    private func apply(_ guidance: String, to store: GlobalSettingsStore) -> Bool {
        var profile = store.globalAgentModelsProfile()
        profile.oracleReconciliationGuidance = guidance
        return store.setGlobalAgentModelsProfileWithDeferredSave(profile, contextBuilderWriteIntent: .userInitiated)
    }

    private func makeSettingsURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeferredAgentModelsProfileSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("globalSettings.json")
        try GlobalSettingsFileStore(fileURL: url).save(GlobalSettingsDocument())
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        raw["fixtureFutureField"] = "keep me"
        try JSONSerialization.data(withJSONObject: raw).write(to: url, options: .atomic)
        return url
    }
}
