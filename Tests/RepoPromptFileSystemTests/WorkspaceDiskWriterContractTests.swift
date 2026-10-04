import Foundation
@testable import RepoPromptFileSystem
import XCTest

final class WorkspaceDiskWriterContractTests: XCTestCase {
    func testNormalizationDoesNotBypassInjectedBackendFailure() async throws {
        let fixture = try NormalizationFixture()
        defer { fixture.remove() }
        let called = expectation(description: "Injected normalization backend refused the write")
        let writer = WorkspaceDiskWriter(policy: BytePayloadPolicy(), backend: WorkspaceDiskWriteBackend(
            queuedAtomicWrite: { _, _ in throw InjectedWriteFailure.refused },
            normalizationAtomicWrite: { _, _ in
                called.fulfill()
                throw InjectedWriteFailure.refused
            }
        ))

        let wrote = await writer.writeNormalizationIfUnchanged(
            data: Data("normalized".utf8),
            url: fixture.url,
            expectedFileSize: fixture.fileSize,
            expectedModificationDate: fixture.modificationDate
        )

        XCTAssertFalse(wrote, "Normalization must not fall back to physical I/O when the injected write backend refuses it")
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        await fulfillment(of: [called], timeout: 1)
    }

    func testNormalizationUsesCustomBackendWithoutModifyingPhysicalFile() async throws {
        let fixture = try NormalizationFixture()
        defer { fixture.remove() }
        let normalized = Data("normalized".utf8)
        let called = expectation(description: "Custom backend receives normalization bytes and URL")
        let writer = WorkspaceDiskWriter(policy: BytePayloadPolicy(), backend: WorkspaceDiskWriteBackend(
            queuedAtomicWrite: { _, _ in XCTFail("Normalization must not use the queued backend operation") },
            normalizationAtomicWrite: { data, url in
                XCTAssertEqual(data, normalized)
                XCTAssertEqual(url, fixture.url)
                called.fulfill()
            }
        ))

        let wrote = await writer.writeNormalizationIfUnchanged(
            data: normalized,
            url: fixture.url,
            expectedFileSize: fixture.fileSize,
            expectedModificationDate: fixture.modificationDate
        )

        XCTAssertTrue(wrote)
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        await fulfillment(of: [called], timeout: 1)
    }

    func testDefaultBackendPreservesPhysicalNormalizationWrite() async throws {
        let fixture = try NormalizationFixture()
        defer { fixture.remove() }
        let normalized = Data("normalized".utf8)
        let writer = WorkspaceDiskWriter(policy: BytePayloadPolicy())

        let wrote = await writer.writeNormalizationIfUnchanged(
            data: normalized,
            url: fixture.url,
            expectedFileSize: fixture.fileSize,
            expectedModificationDate: fixture.modificationDate
        )

        XCTAssertTrue(wrote)
        XCTAssertEqual(try Data(contentsOf: fixture.url), normalized)
    }

    func testNormalizationRejectsStaleFileStampBeforeCallingBackend() async throws {
        let fixture = try NormalizationFixture()
        defer { fixture.remove() }
        let writer = WorkspaceDiskWriter(policy: BytePayloadPolicy(), backend: WorkspaceDiskWriteBackend(
            queuedAtomicWrite: { _, _ in XCTFail("Stale normalization must not enqueue a write") },
            normalizationAtomicWrite: { _, _ in XCTFail("Stale normalization must not invoke the backend") }
        ))

        let wrongSize = await writer.writeNormalizationIfUnchanged(
            data: Data("normalized".utf8),
            url: fixture.url,
            expectedFileSize: fixture.fileSize + 1,
            expectedModificationDate: fixture.modificationDate
        )
        let wrongDate = await writer.writeNormalizationIfUnchanged(
            data: Data("normalized".utf8),
            url: fixture.url,
            expectedFileSize: fixture.fileSize,
            expectedModificationDate: fixture.modificationDate.addingTimeInterval(1)
        )

        XCTAssertFalse(wrongSize)
        XCTAssertFalse(wrongDate)
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
    }

    func testNormalizationRejectsPendingWriteBeforeCallingBackend() async throws {
        let fixture = try NormalizationFixture()
        defer { fixture.remove() }
        let writes = WriteGate()
        let writer = WorkspaceDiskWriter(policy: BytePayloadPolicy(), backend: WorkspaceDiskWriteBackend(
            queuedAtomicWrite: { data, _ in await writes.write(data) },
            normalizationAtomicWrite: { _, _ in XCTFail("Normalization must not interleave with the pending write") }
        ))
        await writer.enqueue(data: Data("queued".utf8), url: fixture.url)
        await writes.waitForFirstWrite()

        let wrote = await writer.writeNormalizationIfUnchanged(
            data: Data("normalized".utf8),
            url: fixture.url,
            expectedFileSize: fixture.fileSize,
            expectedModificationDate: fixture.modificationDate
        )

        XCTAssertFalse(wrote)
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        await writes.releaseFirstWrite()
        await writer.flush(url: fixture.url)
    }

    func testSelectionLookupKeepsKeyWhenIncomingMetadataHasNoSelection() async {
        let writes = WriteGate()
        let writer = WorkspaceDiskWriter(policy: SelectionLookupPolicy(), backend: WorkspaceDiskWriteBackend(
            queuedAtomicWrite: { data, _ in await writes.write(data) },
            normalizationAtomicWrite: { _, _ in XCTFail("This fixture only queues writes") }
        ))
        let url = URL(fileURLWithPath: "/fixture/selection.json")
        await writer.enqueueWorkspace(
            data: Data(),
            url: url,
            metadata: SelectionMetadata(key: "tab", revision: 2, selection: "latest")
        )
        await writes.waitForFirstWrite()
        await writer.enqueueWorkspace(
            data: Data("fallback".utf8),
            url: url,
            metadata: SelectionMetadata(key: "tab", revision: 1, selection: nil)
        )
        let flush = Task { await writer.flush(url: url) }
        await writes.releaseFirstWrite()
        await flush.value
        let payloads = await writes.snapshot()
        XCTAssertEqual(payloads, [Data("latest".utf8), Data("latest".utf8)])
    }

    func testFlushWaitsForInFlightAndCoalescedPayload() async {
        let writes = WriteGate()
        let writer = WorkspaceDiskWriter(policy: BytePayloadPolicy(), backend: WorkspaceDiskWriteBackend(
            queuedAtomicWrite: { data, _ in await writes.write(data) },
            normalizationAtomicWrite: { _, _ in XCTFail("This fixture only queues writes") }
        ))
        let url = URL(fileURLWithPath: "/fixture/workspace.json")
        await writer.enqueue(data: Data("first".utf8), url: url)
        await writes.waitForFirstWrite()
        await writer.enqueue(data: Data("second".utf8), url: url)
        await writer.enqueue(data: Data("newest".utf8), url: url)
        let flush = Task { await writer.flush(url: url) }
        await writes.releaseFirstWrite()
        await flush.value
        let payloads = await writes.snapshot()
        XCTAssertEqual(payloads, [Data("first".utf8), Data("newest".utf8)])
    }
}

private struct NormalizationFixture {
    let directory: URL
    let url: URL
    let original: Data
    let fileSize: Int64
    let modificationDate: Date

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("workspace.json")
        original = Data("original".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        fileSize = try Int64(XCTUnwrap(values.fileSize))
        modificationDate = try XCTUnwrap(values.contentModificationDate)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum InjectedWriteFailure: Error {
    case refused
}

private struct BytePayloadPolicy: WorkspaceDiskWritePolicy {
    typealias Metadata = UInt64
    typealias Selection = UInt64
    typealias SelectionKey = String

    func payloadIdentity(metadata: UInt64?, data: Data) -> WorkspaceDiskPayloadIdentity? {
        nil
    }

    func selectionKey(metadata: UInt64?) -> String? {
        nil
    }

    func selectionRecord(metadata: UInt64?) -> WorkspaceDiskSelectionRecord<String, UInt64, UInt64>? {
        nil
    }

    func selectionRevision(metadata: UInt64) -> UInt64 {
        metadata
    }

    func shouldKeepExistingPayload(existing: WorkspaceDiskPayloadIdentity?, incoming: WorkspaceDiskPayloadIdentity?, metadata: UInt64?, url: URL) -> Bool {
        false
    }

    func effectivePayloadForWrite(data: Data, identity: WorkspaceDiskPayloadIdentity?, url: URL, metadata: UInt64?, latestSelection: WorkspaceDiskSelectionRecord<String, UInt64, UInt64>?, lastWrittenRevision: UInt64) -> WorkspaceDiskEffectivePayload<UInt64, String> {
        WorkspaceDiskEffectivePayload(data: data, metadata: metadata, selectionKey: nil, effectiveSelectionRevision: 0, shouldWrite: true)
    }

    func trace(_ event: String, metadata: UInt64?, url: URL, extra: [String: String]) {}
}

private struct SelectionMetadata {
    let key: String
    let revision: UInt64
    let selection: String?
}

private struct SelectionLookupPolicy: WorkspaceDiskWritePolicy {
    typealias Metadata = SelectionMetadata
    typealias Selection = String
    typealias SelectionKey = String

    func payloadIdentity(metadata: Metadata?, data: Data) -> WorkspaceDiskPayloadIdentity? {
        nil
    }

    func selectionKey(metadata: Metadata?) -> String? {
        metadata?.key
    }

    func selectionRecord(metadata: Metadata?) -> WorkspaceDiskSelectionRecord<String, String, Metadata>? {
        guard let metadata, let selection = metadata.selection else { return nil }
        return WorkspaceDiskSelectionRecord(
            key: metadata.key,
            revision: metadata.revision,
            selection: selection,
            metadata: metadata
        )
    }

    func selectionRevision(metadata: Metadata) -> UInt64 {
        metadata.revision
    }

    func shouldKeepExistingPayload(existing: WorkspaceDiskPayloadIdentity?, incoming: WorkspaceDiskPayloadIdentity?, metadata: Metadata?, url: URL) -> Bool {
        false
    }

    func effectivePayloadForWrite(data: Data, identity: WorkspaceDiskPayloadIdentity?, url: URL, metadata: Metadata?, latestSelection: WorkspaceDiskSelectionRecord<String, String, Metadata>?, lastWrittenRevision: UInt64) -> WorkspaceDiskEffectivePayload<Metadata, String> {
        WorkspaceDiskEffectivePayload(
            data: latestSelection.map { Data($0.selection.utf8) } ?? data,
            metadata: metadata,
            selectionKey: metadata?.key,
            effectiveSelectionRevision: latestSelection?.revision ?? 0,
            shouldWrite: true
        )
    }

    func trace(_ event: String, metadata: Metadata?, url: URL, extra: [String: String]) {}
}

private actor WriteGate {
    private var payloads: [Data] = []
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var firstWriteWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func write(_ data: Data) async {
        payloads.append(data)
        guard payloads.count == 1 else { return }
        entryWaiter?.resume()
        entryWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { firstWriteWaiter = $0 }
    }

    func waitForFirstWrite() async {
        if !payloads.isEmpty {
            return
        }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func releaseFirstWrite() {
        released = true
        firstWriteWaiter?.resume()
        firstWriteWaiter = nil
    }

    func snapshot() -> [Data] {
        payloads
    }
}
