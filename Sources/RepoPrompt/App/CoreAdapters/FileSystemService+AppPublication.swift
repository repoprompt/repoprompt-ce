import Combine
import RepoPromptCore

private final class FileSystemDeltaPublisherBridge: @unchecked Sendable {
    let subject = PassthroughSubject<FileSystemDeltaPublication, Never>()
    var subscription: FileSystemDeltaPublicationSubscription?

    func receive(_ publication: FileSystemDeltaPublication) -> Bool {
        guard let correlationID = publication.correlationID else {
            subject.send(publication)
            return true
        }
        let active = EditFlowPerf.makeLifecycleCorrelationIfActive()
        let correlation = EditFlowPerf.LifecycleCorrelation(
            id: correlationID,
            captureEpoch: active?.captureEpoch
        )
        EditFlowPerf.$currentFileSystemPublicationCorrelation.withValue(correlation) {
            subject.send(publication)
        }
        return true
    }

    func cancel() {
        subscription?.cancel()
        subscription = nil
    }
}

extension FileSystemService {
    /// App-only Combine and EditFlowPerf adaptation over Core's synchronous publication seam.
    nonisolated func publisherForChanges() -> AnyPublisher<FileSystemDeltaPublication, Never> {
        let bridge = FileSystemDeltaPublisherBridge()
        bridge.subscription = subscribeToChanges { [bridge] publication in
            bridge.receive(publication)
        }
        return bridge.subject
            .handleEvents(
                receiveCancel: { [bridge] in bridge.cancel() },
                receiveRequest: { [bridge] _ in _ = bridge }
            )
            .eraseToAnyPublisher()
    }
}
