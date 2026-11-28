import RepoPromptSettingsCore
import SwiftUI

/// Displays preferences only. There is intentionally no selection binding or write action yet.
struct SubscriptionAccountsReadOnlySection: View {
    @ObservedObject private var store = GlobalSettingsStore.shared

    var body: some View {
        let catalog = try? store.subscriptionProfileCatalog()
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                providerRows("Codex", snapshot: .init(backend: .codex, catalog: catalog))
                Divider()
                providerRows("Claude Code", snapshot: .init(backend: .claudeCode, catalog: catalog))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Label("Subscription Account Selection", systemImage: "person.crop.circle.badge.exclamationmark")
        }
    }

    private func providerRows(_ title: String, snapshot: SubscriptionAccountSettingsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)

            Text(reason(for: snapshot.gate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch snapshot.defaultSelection {
            case nil:
                Text("Saved subscription account preferences are unavailable.")
                    .font(.caption)
            case .legacy?:
                LabeledContent("Saved default", value: "Existing CLI account")
            case .profile?:
                if let row = snapshot.rows.first(where: \.isDefault) {
                    LabeledContent("Saved default") { Text(row.label) }
                }
            }

            if snapshot.defaultSelection != nil, snapshot.rows.isEmpty {
                Text("No named accounts saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.rows) { row in
                        HStack {
                            Text(row.label)
                            Spacer()
                            if row.isArchived {
                                Text("Archived").foregroundStyle(.secondary)
                            } else if row.isDefault {
                                Text("Saved default").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func reason(for gate: SubscriptionAccountSettingsSnapshot.Gate) -> LocalizedStringKey {
        switch gate {
        case .codexIdentityAndIsolationUnverified:
            "Read-only: Codex account identity and isolation have not been verified."
        case .claudeIdentityUnverified:
            "Read-only: Claude Code has no verified stable account identity."
        }
    }
}
