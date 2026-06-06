import SwiftUI

struct SecureStorageRepairBanner: View {
    let openRepair: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Legacy secure storage repair")
                    .font(.headline)
                Text("Older official builds may have values in a legacy Keychain service. Review and import them explicitly; no legacy scan runs at startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review…", action: openRepair)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25))
        }
    }
}

struct SecureStorageRepairView: View {
    @ObservedObject var viewModel: SecureStorageRepairViewModel
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var replacementAccount: SecureStorageAccount?
    @State private var deletionAccount: SecureStorageAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repair Legacy Secure Storage")
                        .font(.title2.weight(.semibold))
                    Text("Scanning is noninteractive. Importing a selected account may request Keychain approval. Existing v2 values are preserved unless you explicitly replace one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            if !viewModel.hasScanned {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No legacy accounts have been inspected.")
                    Button("Scan Known Accounts") {
                        Task { await viewModel.scan() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(viewModel.records) { record in
                    repairRow(record)
                }
                .overlay {
                    if viewModel.isScanning {
                        ProgressView()
                    }
                }

                HStack {
                    Text("Legacy values are retained by default for rollback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") {
                        Task { await viewModel.scan() }
                    }
                    .disabled(viewModel.isScanning || viewModel.activeAccount != nil)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
        .confirmationDialog(
            "Replace the existing v2 value?",
            isPresented: replacementConfirmationPresented,
            presenting: replacementAccount
        ) { account in
            Button("Replace v2 Value", role: .destructive) {
                Task {
                    if await viewModel.importAccount(account, replaceExistingTarget: true)?.state == .imported {
                        onImported()
                    }
                }
            }
        } message: { account in
            Text("This replaces the current v2 value for \(account.displayName). The legacy value will still be kept.")
        }
        .confirmationDialog(
            "Delete the verified legacy value?",
            isPresented: deletionConfirmationPresented,
            presenting: deletionAccount
        ) { account in
            Button("Delete Legacy Value", role: .destructive) {
                Task { await viewModel.deleteLegacy(account) }
            }
        } message: { account in
            Text("Deleting the legacy value for \(account.displayName) can make rollback to an older build require re-entry.")
        }
    }

    private func repairRow(_ record: SecureStorageRepairRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: record.state))
                .foregroundStyle(iconColor(for: record.state))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.account.displayName)
                Text(statusText(for: record.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.activeAccount == record.account {
                ProgressView()
                    .controlSize(.small)
            } else {
                actions(for: record)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(for record: SecureStorageRepairRecord) -> some View {
        switch record.state {
        case .importable, .interactionRequired, .cancelled, .failed:
            Button("Import") {
                Task {
                    if await viewModel.importAccount(record.account)?.state == .imported {
                        onImported()
                    }
                }
            }
        case .conflict:
            Button("Replace v2…") {
                replacementAccount = record.account
            }
        case .imported where record.legacyDeletionAvailable:
            Button("Delete Legacy…", role: .destructive) {
                deletionAccount = record.account
            }
        case .absent, .imported:
            EmptyView()
        }
    }

    private var replacementConfirmationPresented: Binding<Bool> {
        Binding(
            get: { replacementAccount != nil },
            set: { if !$0 { replacementAccount = nil } }
        )
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deletionAccount != nil },
            set: { if !$0 { deletionAccount = nil } }
        )
    }

    private func statusText(for state: SecureStorageRepairState) -> String {
        switch state {
        case .absent: "No legacy value"
        case .importable: "Ready to import"
        case .interactionRequired: "Import may require Keychain approval"
        case .imported: "Imported and verified"
        case .conflict: "A different v2 value already exists"
        case .cancelled: "Import was cancelled"
        case .failed: "Repair failed; retry this account"
        }
    }

    private func iconName(for state: SecureStorageRepairState) -> String {
        switch state {
        case .absent: "minus.circle"
        case .importable, .interactionRequired: "arrow.right.circle"
        case .imported: "checkmark.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func iconColor(for state: SecureStorageRepairState) -> Color {
        switch state {
        case .imported: .green
        case .conflict, .interactionRequired: .orange
        case .failed: .red
        default: .secondary
        }
    }
}
