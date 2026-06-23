import Foundation
import SwiftUI

extension EnvironmentValues {
    @Entry var showDatesInMessageTimestamps: Bool = false
    @Entry var messageTimestampNow: Date = .now
}

@MainActor
final class MessageTimestampBoundaryClock: ObservableObject {
    static let shared = MessageTimestampBoundaryClock()

    @Published private(set) var now: Date

    private let notificationCenter: NotificationCenter
    private var notificationTokens: [NSObjectProtocol] = []
    private var timer: Timer?

    init(now: Date = .now, notificationCenter: NotificationCenter = .default) {
        self.now = now
        self.notificationCenter = notificationCenter
        notificationTokens = [
            Notification.Name.NSCalendarDayChanged,
            Notification.Name.NSSystemClockDidChange,
            Notification.Name.NSSystemTimeZoneDidChange,
            NSLocale.currentLocaleDidChangeNotification
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
        scheduleNextBoundary()
    }

    deinit {
        timer?.invalidate()
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
    }

    static func nextRefreshDate(after date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? date.addingTimeInterval(60 * 60)
    }

    private func refresh() {
        now = .now
        scheduleNextBoundary()
    }

    private func scheduleNextBoundary() {
        timer?.invalidate()
        let timer = Timer(
            fire: Self.nextRefreshDate(after: now, calendar: .autoupdatingCurrent),
            interval: 0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

private struct MessageTimestampEnvironmentModifier: ViewModifier {
    @ObservedObject private var clock = MessageTimestampBoundaryClock.shared
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    func body(content: Content) -> some View {
        content
            .environment(\.showDatesInMessageTimestamps, globalSettings.showDatesInMessageTimestamps())
            .environment(\.messageTimestampNow, clock.now)
    }
}

extension View {
    func messageTimestampEnvironment() -> some View {
        modifier(MessageTimestampEnvironmentModifier())
    }
}

struct MessageTimestampText: View {
    let date: Date

    @Environment(\.showDatesInMessageTimestamps) private var showDatesInMessageTimestamps
    @Environment(\.messageTimestampNow) private var messageTimestampNow

    var body: some View {
        Text(MessageTimestampFormatter.string(
            from: date,
            includeDateContext: showDatesInMessageTimestamps,
            now: messageTimestampNow
        ))
    }
}
