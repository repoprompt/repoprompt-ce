import Foundation

/// Pure, deterministic ordering for outbound dashboard rows.
enum AgentMonitorDashboardSortPolicy {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    static func sorted(
        _ rows: [AgentMonitorPillProps.Outbound]
    ) -> [AgentMonitorPillProps.Outbound] {
        rows.sorted(by: compare)
    }

    private static func compare(
        _ lhs: AgentMonitorPillProps.Outbound,
        _ rhs: AgentMonitorPillProps.Outbound
    ) -> Bool {
        let lhsIsActive = lhs.status.isActiveForDashboardOrdering
        let rhsIsActive = rhs.status.isActiveForDashboardOrdering
        if lhsIsActive != rhsIsActive {
            return lhsIsActive
        }

        let lhsLocation = normalizedLocation(lhs.locationLabel)
        let rhsLocation = normalizedLocation(rhs.locationLabel)
        switch (lhsLocation, rhsLocation) {
        case let (lhsLocation?, rhsLocation?):
            if let result = compareFolded(lhsLocation, rhsLocation) {
                return result
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if let result = compareFolded(lhs.displayName, rhs.displayName) {
            return result
        }

        let lhsTarget = lhs.targetSessionID.uuidString
        let rhsTarget = rhs.targetSessionID.uuidString
        if lhsTarget != rhsTarget {
            return lhsTarget < rhsTarget
        }
        return lhs.linkID.uuidString < rhs.linkID.uuidString
    }

    private static func normalizedLocation(_ location: String?) -> String? {
        guard let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    /// `nil` means equal after fixed-locale case/diacritic folding.
    private static func compareFolded(_ lhs: String, _ rhs: String) -> Bool? {
        let lhsFolded = lhs.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: foldingLocale
        )
        let rhsFolded = rhs.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: foldingLocale
        )
        guard lhsFolded != rhsFolded else { return nil }
        return lhsFolded < rhsFolded
    }
}
