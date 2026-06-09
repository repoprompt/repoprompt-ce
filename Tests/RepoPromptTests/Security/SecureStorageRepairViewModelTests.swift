import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class SecureStorageRepairViewModelTests: XCTestCase {
    func testInitializationDoesNotScanUntilUserInvokesScan() async {
        let legacy = CountingSecureStorageBackend()
        let target = CountingSecureStorageBackend()
        let service = SecureStorageRepairService(
            accounts: [.anthropicAPI],
            legacyStore: legacy,
            targetStore: target
        )

        let viewModel = SecureStorageRepairViewModel(service: service)

        XCTAssertTrue(viewModel.isAvailable)
        XCTAssertFalse(viewModel.hasScanned)
        XCTAssertEqual(legacy.getCount, 0)
        XCTAssertEqual(target.getCount, 0)

        await viewModel.scan()

        XCTAssertTrue(viewModel.hasScanned)
        XCTAssertEqual(viewModel.records.map(\.state), [.absent])
        XCTAssertEqual(legacy.getCount, 1)
        XCTAssertEqual(target.getCount, 0)
    }
}

private final class CountingSecureStorageBackend: SecureKeyValueStorageBackend, @unchecked Sendable {
    let persistsValuesAcrossLaunches = true

    private(set) var getCount = 0
    private let lock = NSLock()

    func save(_ value: String, for key: String, accessMode: SecureStorageAccessMode) throws {}

    func get(for key: String, accessMode: SecureStorageAccessMode) throws -> String {
        lock.lock()
        getCount += 1
        lock.unlock()
        throw SecureStorageError.itemNotFound
    }

    func delete(for key: String, accessMode: SecureStorageAccessMode) throws {}
}
