import Foundation

final class DurableArtifactReadLease {
    let store: LocalDurableArtifactStore
    let expectation: DurableArtifactObjectExpectation
    let metadata: DurableArtifactObjectMetadata
    let objectParent: DurableArtifactDirectory
    let objectIdentity: DurableArtifactFileIdentity

    private var objectDescriptor: DurableArtifactDescriptor?
    private var objectLock: DurableArtifactDescriptor?
    private var layoutLock: DurableArtifactDescriptor?
    private let stateLock = NSLock()
    private var reading = false
    private var closeRequested = false

    init(
        store: LocalDurableArtifactStore,
        expectation: DurableArtifactObjectExpectation,
        metadata: DurableArtifactObjectMetadata,
        objectParent: DurableArtifactDirectory,
        objectDescriptor: DurableArtifactDescriptor,
        objectIdentity: DurableArtifactFileIdentity,
        objectLock: DurableArtifactDescriptor,
        layoutLock: DurableArtifactDescriptor
    ) {
        self.store = store
        self.expectation = expectation
        self.metadata = metadata
        self.objectParent = objectParent
        self.objectDescriptor = objectDescriptor
        self.objectIdentity = objectIdentity
        self.objectLock = objectLock
        self.layoutLock = layoutLock
    }

    var objectID: DurableArtifactObjectID {
        expectation.id
    }

    var schemaVersion: UInt32 {
        metadata.schemaVersion
    }

    var canonicalIdentity: Data {
        metadata.canonicalIdentity
    }

    var recordCount: UInt64 {
        metadata.recordCount
    }

    var payloadByteCount: UInt64 {
        metadata.payloadByteCount
    }

    func forEachRecord(_ body: @escaping (Data) throws -> Void) throws {
        stateLock.lock()
        guard !reading, let descriptor = objectDescriptor else {
            stateLock.unlock()
            throw DurableArtifactStoreError.insecureEntry
        }
        reading = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            reading = false
            let detached = closeRequested ? detachDescriptorsLocked() : nil
            stateLock.unlock()
            Self.close(detached)
        }
        _ = try DurableArtifactObjectFrame.validate(
            descriptor: descriptor.rawValue,
            expectedFileSize: objectIdentity.size,
            expected: expectation,
            policy: store.framingPolicy,
            hooks: store.hooks,
            recordBody: body
        )
        guard try DurableArtifactSecureIO.identity(descriptor.rawValue) == objectIdentity,
              try DurableArtifactSecureIO.pathIdentity(
                  parent: objectParent,
                  name: expectation.id.digest.hex
              ) == objectIdentity
        else { throw DurableArtifactStoreError.insecureEntry }
    }

    func close() {
        stateLock.lock()
        guard !reading else {
            closeRequested = true
            stateLock.unlock()
            return
        }
        let detached = detachDescriptorsLocked()
        stateLock.unlock()
        Self.close(detached)
    }

    private typealias DetachedDescriptors = (
        object: DurableArtifactDescriptor?,
        objectLease: DurableArtifactDescriptor?,
        layoutLease: DurableArtifactDescriptor?
    )

    private func detachDescriptorsLocked() -> DetachedDescriptors {
        closeRequested = true
        let detached = (objectDescriptor, objectLock, layoutLock)
        objectDescriptor = nil
        objectLock = nil
        layoutLock = nil
        return detached
    }

    private static func close(_ detached: DetachedDescriptors?) {
        detached?.object?.close()
        detached?.objectLease?.close()
        detached?.layoutLease?.close()
    }

    deinit {
        close()
    }
}
