import SwiftUI

struct TipBuildHistoryView: View {
    @ObservedObject var store: TipHistoryStore
    @ObservedObject var manager: SparkleUpdaterManager
    @State private var expanded = false

    var body: some View {
        SettingSection(title: "Tip Build History", description: store.isInspectionOnlyContext ? "Browse existing Tip releases and save a verified official binary for inspection. Do not replace this Debug or unknown-identity app." : "Browse recent Tip releases and download a verified build to reinstall manually. Sparkle can’t install older versions automatically.") {
            if let message = manager.updatesDisabledMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                DisclosureGroup("Recent Tip builds", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.historySource == .githubReleases {
                            Label("GitHub release metadata — not a signed history catalog", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Release titles, commit notes, and download metadata are not catalog-signed. Archives must still pass full verification before they are saved. Data-format coverage is unknown.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if store.historySource == .signedCatalog {
                            Text("Source: signed Tip history catalog").font(.caption).foregroundStyle(.secondary)
                        }
                        catalogStatus
                        if let retry = store.catalogRetryAfter, retry > Date() {
                            Text("The server asked you to wait until \(retry.formatted(date: .omitted, time: .standard)) before retrying.").font(.caption)
                        }
                        if !store.rows.isEmpty {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(store.rows) { row in historyRow(row) }
                                }
                            }
                            .frame(maxHeight: 320)
                            if let row = store.rows.first(where: { $0.id == store.selectedTag }) { details(row) }
                            if store.rows.count == 1, store.rows.first?.availability == .installed {
                                if let start = store.historyStartBuild { Text("No other Tip builds yet. History starts with build \(start).") }
                                else { Text("Only the installed build is on this page. Load older builds to see more history.") }
                            }
                        }
                        if store.pageCount > 0 { footer }
                        if store.downloadState != .idle { TipHistoryDownloadNoticeView(store: store) }
                    }
                    .padding(.top, 10)
                }
                .onChange(of: expanded) { _, value in if value { store.loadIfNeeded() } }
            }
        }
    }

    @ViewBuilder private var catalogStatus: some View {
        switch store.catalogState {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text(store.rows.isEmpty ? "Loading recent Tip builds…" : "Refreshing…")
                Button("Cancel") { store.cancelLoad() }
            }
        case let .failed(error):
            if error == .notPublishedYet {
                Text(store.historySource == .githubReleases ? "Couldn’t load existing Tip releases. Retry or view the official release archive." : "The signed catalog is unavailable. Previously authenticated history cannot be replaced with unsigned release metadata.")
                archiveLink
                Button("Retry") { store.refresh() }
            } else {
                Label(store.rows.isEmpty ? error.message : "Couldn’t refresh — showing previously loaded results. \(error.message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Retry") { store.refresh() }
                if store.rows.isEmpty { archiveLink }
            }
        case .loaded:
            if store.rows.isEmpty {
                Text("No usable builds on this page. Load older releases if available, or view all Tip releases on GitHub.")
            }
            if store.historyBehindLatestNotice {
                HStack {
                    Text("History is behind the latest update.").foregroundStyle(.orange)
                    Button("Refresh") { store.refresh() }
                }
            }
        }
    }

    private func historyRow(_ row: TipHistoryRow) -> some View {
        Button {
            store.selectedTag = row.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.entry.title).lineLimit(2).foregroundStyle(.primary)
                    Text(buildDescription(row.entry)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .unavailable = row.availability {
                    Label(row.availability.badge, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(row.availability.badge).font(.caption).foregroundStyle(row.availability == .installed ? .green : .secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(store.selectedTag == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.entry.title), \(buildDescription(row.entry)), \(row.availability.badge)")
        .accessibilityHint("Show build details")
    }

    private func buildDescription(_ entry: TipHistoryEntry) -> String {
        var description = "Tip build \(entry.buildNumber) · v\(entry.marketingVersion) · commit \(entry.shortSHA)"
        if let date = entry.commitDate { description += " · \(date.formatted(date: .abbreviated, time: .omitted))" }
        return description
    }

    private func details(_ row: TipHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(row.entry.title).font(.headline).textSelection(.enabled)
            Text(row.entry.origin == .githubRelease ? "From GitHub source commit/PR messages (unsigned metadata)" : row.entry.titleSource == .reviewed ? "From reviewed release notes" : "From commit messages")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(row.entry.notes.enumerated()), id: \.offset) { _, note in
                Text("• " + note.text).textSelection(.enabled)
            }
            if row.entry.omittedNoteCount > 0 {
                Text(row.entry.origin == .githubRelease ? "and \(row.entry.omittedNoteCount) more change-note lines" : "and \(row.entry.omittedNoteCount) more commits").font(.caption)
            }
            Text("Signing identity: \(row.entry.signingIdentity.rawValue) · \(row.entry.bundleIdentifier) · Team \(row.entry.teamIdentifier)")
                .font(.caption).textSelection(.enabled)
            if !row.entry.hasHistoryUI {
                Text(row.entry.origin == .githubRelease ? "This release may predate the history browser. On an official installation, use Check for Updates to return to the latest version." : "This build has no history browser; use Check for Updates to return to the latest version.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if row.entry.origin == .seed {
                Text("Audited pre-catalog release included in the signed history.").font(.caption).foregroundStyle(.secondary)
            }
            switch row.availability {
            case .installed:
                Button("Installed") {}.disabled(true)
            case let .unavailable(reason):
                Label(reason.message, systemImage: "lock.fill").foregroundStyle(.secondary)
                Button("Download unavailable") {}.disabled(true)
            case let .available(direction, cautions):
                ForEach(Array(cautions.enumerated()), id: \.offset) { _, caution in
                    Label(caution.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if direction == .older, row.entry.origin != .githubRelease, !cautions.contains(.barrierUnknownInstalledOutsideHistory) {
                    Text("No known data-format change between this build and the installed build. This is not a compatibility guarantee.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.canCheckLatest(row.entry, notice: manager.availableUpdate, canInstall: manager.canInstallAvailableUpdate) {
                    Button("Check for Latest Update…") { manager.performAvailableUpdateAction() }
                        .disabled(store.downloadState.isActive)
                    Text("Sparkle rechecks and may offer a newer build. This does not pin installation to the selected build.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(store.isInspectionOnlyContext ? "Download build \(row.entry.buildNumber) for inspection…" : "Download build \(row.entry.buildNumber)…") { store.requestDownload(tag: row.id) }
                        .disabled(store.downloadState.isActive)
                }
                if store.downloadState.isActive { Text("Another download is in progress").font(.caption) }
            }
            if let release = store.repository.releasePageURL(tag: row.id) { Link("View release on GitHub", destination: release) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.olderPageState {
            case .none: EmptyView()
            case .available: Button("Load older builds") { store.loadOlderPage() }
            case .loading:
                HStack {
                    ProgressView("Loading older builds…").controlSize(.small)
                    Button("Cancel") { store.cancelLoad() }
                }
            case let .failed(error):
                Text("Couldn’t load older builds · \(error.message)").foregroundStyle(.orange)
                Button("Retry older page") { store.loadOlderPage() }
            case .exhausted: Text(store.historySource == .githubReleases ? "End of available GitHub release metadata" : "End of recorded history").font(.caption).foregroundStyle(.secondary)
            case .pageLimitReached: archiveLink
            }
            if let refreshed = store.lastRefreshedAt {
                HStack {
                    Text("Updated \(refreshed, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                    Button("Refresh") { store.refresh() }.disabled(store.catalogState == .loading)
                }
            }
            if store.releaseOmittedCount > 0 {
                Text("\(store.releaseOmittedCount) release records omitted because their metadata could not be used.").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(store.rows.count) builds shown · \(store.rows.count(where: { $0.availability.canDownload })) downloadable on this Mac. Availability depends on identity, system requirements, and known downgrade barriers; it does not prove data compatibility.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var archiveLink: some View {
        VStack(alignment: .leading, spacing: 4) {
            Link("View all Tip releases on GitHub", destination: store.repository.releasesIndexURL)
            Text("Downloads from this page aren’t verified by RepoPrompt CE and are not a compatibility recommendation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
