import Combine
import Foundation

@MainActor
final class SecureStorageRepairViewModel: ObservableObject {
    @Published private(set) var records: [SecureStorageRepairRecord] = []
    @Published private(set) var hasScanned = false
    @Published private(set) var isScanning = false
    @Published private(set) var activeAccount: SecureStorageAccount?

    private let service: SecureStorageRepairService?

    init(service: SecureStorageRepairService? = SecureStorageRepairService.makeForCurrentRuntime()) {
        self.service = service
    }

    var isAvailable: Bool {
        service != nil
    }

    func scan() async {
        guard let service else { return }
        isScanning = true
        records = await service.scan()
        hasScanned = true
        isScanning = false
    }

    func importAccount(
        _ account: SecureStorageAccount,
        replaceExistingTarget: Bool = false
    ) async -> SecureStorageRepairRecord? {
        guard let service else { return nil }
        activeAccount = account
        let resolution: SecureStorageConflictResolution = replaceExistingTarget ? .replaceTarget : .preserveTarget
        let record = await service.importAccount(account, resolution: resolution)
        update(record)
        activeAccount = nil
        return record
    }

    func deleteLegacy(_ account: SecureStorageAccount) async {
        guard let service else { return }
        activeAccount = account
        let record = await service.deleteLegacy(account, confirmed: true)
        update(record)
        activeAccount = nil
    }

    private func update(_ record: SecureStorageRepairRecord) {
        if let index = records.firstIndex(where: { $0.account == record.account }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }
}
