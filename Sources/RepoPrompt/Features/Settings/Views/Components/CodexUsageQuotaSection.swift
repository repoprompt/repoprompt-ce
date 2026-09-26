import AppKit
import Combine
import SwiftUI

// SEARCH-HELPER: codex usage limits settings UI, account quota section, observe-only
//
// Compact, observe-only Codex account usage surface for the Codex provider card.
//
// This is account-scoped plan usage. It is deliberately NOT mixed with per-session context
// window usage, which is a different concept with a different lifetime and its own UI.
//
// The section renders nothing until the user opts in. While opted out, no transport,
// process, subscription, or polling exists behind it.

struct CodexUsageQuotaSection: View {
    @ObservedObject private var store: CodexQuotaUIStore
    @ObservedObject private var settingsStore = GlobalSettingsStore.shared

    @MainActor
    init(store: CodexQuotaUIStore = .shared) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { settingsStore.codexUsageQuotaEnabled() },
                set: { newValue in
                    settingsStore.setCodexUsageQuotaEnabled(newValue)
                    // Same transition the MCP write path uses, so both surfaces apply the
                    // flag identically rather than only persisting it.
                    CodexUsageQuotaRuntimeBridge.applyEnabled(newValue)
                }
            )) {
                Text("Show account usage limits")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Reads your Codex plan limits directly from the Codex app server. Observe-only: it never changes which model runs.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content
        }
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshOnForeground()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .hidden:
            EmptyView()

        case let .idle(message):
            // Never a zero, never an empty bar.
            statusRow(message)

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 12)
                Text("Checking usage limits…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case let .unavailable(message):
            statusRow(message)

        case let .loaded(sections, footnote, accountNotice):
            VStack(alignment: .leading, spacing: 10) {
                if let accountNotice {
                    Label(accountNotice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(sections) { section in
                    bucketView(section)
                }

                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                refreshButton
            }
        }
    }

    private func statusRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button(action: { store.refresh() }) {
            if store.isRefreshing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 12)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
        }
        .disabled(store.isRefreshing)
        .buttonStyle(CustomButtonStyle())
    }

    private func bucketView(_ section: CodexQuotaBucketSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                // Bucket-level status accompanies the real per-window figures rather than
                // overwriting them.
                if let statusText = section.statusText {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            ForEach(section.rows) { row in
                windowRow(row)
            }
        }
    }

    private func windowRow(_ row: CodexQuotaWindowRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer(minLength: 8)
                // The printed figure is never clamped, even above a declared bound.
                Text(row.valueText)
                    .font(.caption2)
                    .foregroundColor(row.isReached ? .orange : .primary)
            }

            // A bar is drawn only when there is a real value; the bar clamps, the text does not.
            if let barFraction = row.barFraction {
                ProgressView(value: barFraction)
                    .progressViewStyle(.linear)
                    .tint(row.isReached ? .orange : .accentColor)
                    .frame(height: 3)
            }

            if let detailText = row.detailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
