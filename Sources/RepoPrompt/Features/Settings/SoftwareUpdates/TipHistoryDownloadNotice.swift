import AppKit
import Combine
import SwiftUI

/// App-owned nonmodal surface: closing Settings does not hide an acquisition or
/// forget a committed result. It never launches the downloaded application.
@MainActor
final class TipHistoryDownloadNoticeController {
    private let panel: NSPanel
    private var subscription: AnyCancellable?

    init(store: TipHistoryStore) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 510, height: 510), styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Tip Build Download"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: TipHistoryDownloadNoticeRoot(store: store))
        panel.center()
        subscription = store.$downloadState.combineLatest(store.$confirmationEntry).sink { [weak self] state, confirmation in
            if state == .idle, confirmation == nil { self?.panel.orderOut(nil) }
            else { self?.panel.orderFront(nil) }
        }
    }
}

private struct TipHistoryDownloadNoticeRoot: View {
    @ObservedObject var store: TipHistoryStore

    var body: some View {
        ScrollView {
            TipHistoryDownloadNoticeView(store: store).padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $store.confirmationEntry) { entry in
            TipHistoryOlderBuildConfirmation(store: store, entry: entry)
        }
    }
}

private struct TipHistoryOlderBuildConfirmation: View {
    @ObservedObject var store: TipHistoryStore
    let entry: TipHistoryEntry
    @State private var acknowledgesBackup = false
    @State private var acknowledgesUnknownCoverage = false

    private var availability: TipHistoryAvailability? {
        store.rows.first { $0.id == entry.tag }?.availability
    }

    private var isOlder: Bool {
        if case .available(.older, _) = availability { return true }
        return false
    }

    private var needsUnknownAcknowledgement: Bool {
        if case let .available(_, cautions) = availability { return cautions.contains(.barrierUnknownInstalledOutsideHistory) }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.isInspectionOnlyContext ? "Save official Tip build \(entry.buildNumber) for inspection?" : "Download older Tip build \(entry.buildNumber)?").font(.headline)
            if store.isInspectionOnlyContext {
                Text("You will choose a folder and RepoPrompt will save a verified official binary for inspection only. Do not replace this Debug or unknown-identity app. This is not rollback or cross-identity installation approval; use the official migration/update path for installation.")
                Text("Saving the binary does not install it or migrate data. Before any later installation, back up your data: an older build may not read data or credentials written by a newer one.")
                Text("Automatic update checks in this running app are \(store.automaticallyChecksForUpdates ? "On" : "Off"). This download changes no preferences and makes no claim that an official app shares this app’s settings or identity.")
            } else {
                Text("You will choose a folder and RepoPrompt will download and verify the app. Reinstallation is manual: quit RepoPrompt, replace the actual installed copy in Finder, then open it yourself.")
                Text("There is no automatic undo. Older builds may not read settings, workspace/session data, agent configuration, or credentials written by newer builds. Make a Time Machine backup or a copy of your app data first.")
                Text("Use Check for Updates to return to the newest build; it does not restore data.")
                if entry.origin == .githubRelease {
                    Text("Automatic update checks in this running app are \(store.automaticallyChecksForUpdates ? "On" : "Off"). This download changes no channel or preferences. This historical release’s update/preference behavior has not been source-audited; do not assume it matches the current app.")
                } else {
                    Text("Automatic update checks are \(store.automaticallyChecksForUpdates ? "On" : "Off"). The installed build will keep this setting. This download does not change your channel or preferences.")
                }
            }
            if isOlder {
                Toggle("I have backed up my data and understand that older builds may not read it.", isOn: $acknowledgesBackup)
            }
            if needsUnknownAcknowledgement {
                Toggle("RepoPrompt cannot check data-format changes between these builds; I understand this additional uncertainty.", isOn: $acknowledgesUnknownCoverage)
            }
            if case let .unavailable(reason) = availability {
                Text(reason.message).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.confirmationEntry = nil }.keyboardShortcut(.defaultAction)
                Button("Download and Verify") {
                    store.confirmationEntry = nil
                    store.beginDownload(tag: entry.tag, acknowledgedBackup: acknowledgesBackup, acknowledgedUnknownCoverage: acknowledgesUnknownCoverage)
                }
                .disabled((isOlder && !acknowledgesBackup) || (needsUnknownAcknowledgement && !acknowledgesUnknownCoverage) || availability?.canDownload != true)
            }
        }
        .padding(24)
        .frame(width: 510)
        .onExitCommand { store.confirmationEntry = nil }
    }
}

struct TipHistoryDownloadNoticeView: View {
    @ObservedObject var store: TipHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = store.acquiredEntry {
                Text("Tip build \(entry.buildNumber) · \(entry.shortSHA)").font(.headline)
                Text(entry.title).font(.subheadline)
            }
            switch store.downloadState {
            case .idle:
                EmptyView()
            case .choosingDestination:
                Text("Choose a destination for the verified app.")
                cancelButton
            case let .downloading(_, received, total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("Downloading \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .accessibilityLabel("Download progress: \(received) of \(total) bytes")
                cancelButton
            case .verifying:
                ProgressView("Verifying signature and integrity…")
                cancelButton
            case .committing:
                ProgressView("Saving verified app…")
            case let .ready(_, appURL, folderURL):
                Label("Verified build saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(folderURL.path).font(.caption).textSelection(.enabled)
                if store.acquiredForInspectionOnly {
                    Text("Official binary saved for inspection only — not rollback approval.").font(.headline)
                    Text("Do not replace your Debug or unknown-identity app with this binary. The current app’s identity, preferences, data, and credentials are not proven compatible with it.")
                        .foregroundStyle(.orange)
                    Text("If you later choose to install an official app, use the official migration/update path. Saving this binary neither installs it nor authorizes crossing the application-identity boundary.")
                } else {
                    Text("1. Quit RepoPrompt CE.")
                    Text("2. In Finder, replace your actual installed copy with RepoPrompt CE.app from this folder (normally drag it to Applications and choose Replace). Do not keep competing runnable copies.")
                    Text("Installed copy: \(Bundle.main.bundleURL.path)").font(.caption).textSelection(.enabled)
                    Text("If the installed copy is on a mounted or read-only volume, move the verified app to your normal writable application location manually.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("3. Open the replaced app. macOS may confirm that it was downloaded from the internet.")
                    if store.acquiredEntry?.origin == .githubRelease {
                        Text("4. Review the historical app’s update settings before using it. Its update/preference and data-format behavior have not been source-audited. Use the official update path to return to a current release.")
                    } else {
                        Text("4. If automatic checks are on, the newest Tip build is shown as available, not installed automatically. Use Check for Updates to return to the newest build.")
                    }
                    Text("There is no automatic undo or data restore. Older builds may not read data or credentials written by newer builds.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Show in Finder") { store.revealDownload() }
                        .hoverTooltip(appURL.path)
                    if !store.acquiredForInspectionOnly {
                        Button("Quit RepoPrompt CE…") { NSApp.terminate(nil) }
                    }
                    Button("Done") { store.clearDownloadResult() }
                }
            case let .failed(tag, error):
                Label(error.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                if let status = store.downloadHTTPStatus {
                    Text("The release server returned HTTP \(status).").font(.caption)
                }
                if let retryAfter = store.retryAfter, retryAfter > Date() {
                    Text("The server asked you to wait until \(retryAfter.formatted(date: .omitted, time: .standard)).")
                        .font(.caption)
                }
                if let entry = store.acquiredEntry, let release = store.repository.releasePageURL(tag: entry.tag) {
                    Link("View release on GitHub", destination: release)
                    Text("Browser downloads are not verified by RepoPrompt CE and are not a compatibility recommendation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if store.offersDownloadRetry {
                        // Retry returns to the detail/confirmation flow rather
                        // than reusing consent from a different safety interval.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Button(error == .accessDenied ? "Choose Another Folder…" : "Retry…") {
                                store.requestDownload(tag: tag)
                            }
                            .disabled(!store.canRetryDownload)
                        }
                    }
                    Button("Dismiss") { store.clearDownloadResult() }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cancelButton: some View {
        Button("Cancel Download") { store.cancelDownload() }
    }
}
