import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import XCTest

#if DEBUG
    @MainActor
    final class PromptInitialModelRefreshLifecycleTests: XCTestCase {
        func testDefaultRefreshIsOwnedAndCloseJoinWaitsForItsLoadBoundary() async {
            let backend = TestSecureStorageBackend()
            let keys = KeyManager(secureService: SecureKeysService(secureStorage: backend))
            let queries = AIQueriesService(keyManager: keys)
            let entered = XCTestExpectation(description: "default refresh reached the existing stored-data boundary")
            let gate = Gate()
            let api = APISettingsViewModel(
                aiQueriesService: queries, keyManager: keys, loadStoredDataOnInit: false,
                storedDataLoadBoundary: {
                    entered.fulfill()
                    await gate.wait()
                }
            )
            let prompt = PromptViewModel(
                fileManager: WorkspaceFilesViewModel(), aiQueriesService: queries,
                apiSettingsViewModel: api, windowID: -9495,
                settingsManager: WindowSettingsManager(windowID: -9495)
            )
            await fulfillment(of: [entered], timeout: 5)
            let joinStarted = XCTestExpectation(description: "the owner entered its close join")
            var joinFinished = false
            let join = Task { @MainActor in
                joinStarted.fulfill()
                await prompt.awaitInitialModelRefreshCompletion()
                joinFinished = true
            }
            await fulfillment(of: [joinStarted], timeout: 5)
            XCTAssertFalse(joinFinished, "The constructor task is still parked at its controlled load boundary.")
            api.prepareForWindowClose()
            prompt.cancelInitialModelRefreshForWindowClose()
            gate.release()
            await join.value
            XCTAssertTrue(joinFinished)
            XCTAssertTrue(backend.calls.isEmpty, "Closing at the boundary must prevent credential loading and downstream discovery.")
            XCTAssertFalse(api.test_hasFinishedInitialStoredDataLoad)
        }

        @MainActor
        private final class Gate {
            private var released = false
            private var continuation: CheckedContinuation<Void, Never>?

            func wait() async {
                guard !released else { return }
                await withCheckedContinuation { continuation = $0 }
            }

            func release() {
                released = true
                continuation?.resume()
                continuation = nil
            }
        }
    }
#endif
