import Combine
import SwiftUI

private enum UpdateAvailableToolbarSnapshot: Equatable {
    case hidden
    case available(notice: AvailableUpdateNotice, canCheckForUpdates: Bool)
}

@MainActor
private final class UpdateAvailableToolbarStateObserver: ObservableObject {
    @Published private(set) var snapshot: UpdateAvailableToolbarSnapshot

    private var cancellables = Set<AnyCancellable>()

    init(sparkleManager: SparkleUpdaterManager) {
        snapshot = Self.makeSnapshot(
            availableUpdate: sparkleManager.availableUpdate,
            canCheckForUpdates: sparkleManager.canCheckForUpdates
        )

        Publishers.CombineLatest(
            sparkleManager.$availableUpdate.removeDuplicates(),
            sparkleManager.$canCheckForUpdates.removeDuplicates()
        )
        .map(Self.makeSnapshot(availableUpdate:canCheckForUpdates:))
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] snapshot in
            guard let self, self.snapshot != snapshot else { return }
            self.snapshot = snapshot
        }
        .store(in: &cancellables)
    }

    private nonisolated static func makeSnapshot(
        availableUpdate: AvailableUpdateNotice?,
        canCheckForUpdates: Bool
    ) -> UpdateAvailableToolbarSnapshot {
        guard let availableUpdate else { return .hidden }
        return .available(notice: availableUpdate, canCheckForUpdates: canCheckForUpdates)
    }
}

/// Compact toolbar affordance for a known available app update.
@MainActor
struct UpdateAvailableToolbarPill: View {
    private let sparkleManager: SparkleUpdaterManager
    @StateObject private var observer: UpdateAvailableToolbarStateObserver

    init(sparkleManager: SparkleUpdaterManager) {
        self.sparkleManager = sparkleManager
        _observer = StateObject(wrappedValue: UpdateAvailableToolbarStateObserver(sparkleManager: sparkleManager))
    }

    var body: some View {
        switch observer.snapshot {
        case .hidden:
            EmptyView()
        case let .available(notice, canCheckForUpdates):
            Button {
                sparkleManager.installUpdate()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .imageScale(.small)
                    Text(notice.toolbarLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 76)
                .foregroundStyle(.white)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .disabled(!canCheckForUpdates)
            .hoverTooltip(canCheckForUpdates ? notice.availableTooltip : notice.notReadyTooltip, .bottom)
            .accessibilityLabel(notice.accessibilityLabel)
            .accessibilityHint(accessibilityHint(canCheckForUpdates: canCheckForUpdates))
        }
    }

    private func accessibilityHint(canCheckForUpdates: Bool) -> String {
        if canCheckForUpdates {
            return "Opens Sparkle's release notes and install dialog."
        }
        return "Sparkle is not ready to check for updates yet."
    }
}
