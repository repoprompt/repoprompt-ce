import Foundation

/// Non-secret intent, published only after settings mutations. Raw selections deliberately
/// distinguish absent fields from blank and unknown persisted values.
package struct RoutingSettingsSnapshot: Equatable {
    package let routerEnabled: Bool
    package let selectedBackendRawValue: String?
    package let autoEffortEnabled: Bool
    package let autoEffortBackendRawValue: String?
    package let routerRevision: UInt64
    package let autoEffortRevision: UInt64

    package init(
        routerEnabled: Bool,
        selectedBackendRawValue: String?,
        autoEffortEnabled: Bool,
        routerRevision: UInt64,
        autoEffortBackendRawValue: String? = nil,
        autoEffortRevision: UInt64 = 0
    ) {
        self.routerEnabled = routerEnabled
        self.selectedBackendRawValue = selectedBackendRawValue
        self.autoEffortEnabled = autoEffortEnabled
        self.autoEffortBackendRawValue = autoEffortBackendRawValue
        self.routerRevision = routerRevision
        self.autoEffortRevision = autoEffortRevision
    }

    package struct Key: Equatable {
        package let routerEnabled: Bool
        package let selectedBackendRawValue: String?
        package let autoEffortEnabled: Bool
        package let autoEffortBackendRawValue: String?
    }

    package var key: Key {
        .init(
            routerEnabled: routerEnabled,
            selectedBackendRawValue: selectedBackendRawValue,
            autoEffortEnabled: autoEffortEnabled,
            autoEffortBackendRawValue: autoEffortBackendRawValue
        )
    }
}
