import Combine
import SwiftUI

private enum UpdateAvailableToolbarSnapshot: Equatable {
    case hidden
    case available(notice: AvailableUpdateNotice, canPerformAction: Bool, manualDownload: Bool)
}

@MainActor
private final class UpdateAvailableToolbarStateObserver: ObservableObject {
    @Published private(set) var snapshot: UpdateAvailableToolbarSnapshot

    private var cancellables = Set<AnyCancellable>()

    init(sparkleManager: SparkleUpdaterManager) {
        snapshot = Self.makeSnapshot(
            availableUpdate: sparkleManager.availableUpdate,
            canCheckForUpdates: sparkleManager.canCheckForUpdates,
            installationBlockedMessage: sparkleManager.updateInstallationBlockedMessage
        )

        Publishers.CombineLatest3(
            sparkleManager.$availableUpdate.removeDuplicates(),
            sparkleManager.$canCheckForUpdates.removeDuplicates(),
            sparkleManager.$updateInstallationBlockedMessage.removeDuplicates()
        )
        .map(Self.makeSnapshot(availableUpdate:canCheckForUpdates:installationBlockedMessage:))
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
        canCheckForUpdates: Bool,
        installationBlockedMessage: String?
    ) -> UpdateAvailableToolbarSnapshot {
        guard let availableUpdate else { return .hidden }
        let manualDownload = installationBlockedMessage != nil
        let canPerformAction = manualDownload
            ? SparkleUpdaterManager.updateChannel(forAppcastItemURL: availableUpdate.downloadURL) == availableUpdate.channel
            : canCheckForUpdates
        return .available(
            notice: availableUpdate,
            canPerformAction: canPerformAction,
            manualDownload: manualDownload
        )
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
        case let .available(notice, canPerformAction, manualDownload):
            Button {
                sparkleManager.performAvailableUpdateAction()
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
            .disabled(!canPerformAction)
            .hoverTooltip(
                canPerformAction
                    ? manualDownload ? "Open the trusted-channel update download in your browser" : notice.availableTooltip
                    : notice.notReadyTooltip,
                .bottom
            )
            .accessibilityLabel(notice.accessibilityLabel)
            .accessibilityHint(
                canPerformAction
                    ? manualDownload ? "Opens the trusted-channel update download in your browser." : notice.accessibilityHint
                    : "The update action is not available yet."
            )
        }
    }
}
