import RepoPromptDomainRuntime
import SwiftUI

/// Uses the main library's exact filtering and recency policy, with no name-based exclusions.
struct CommandCenterProjectPicker: View {
    let projects: [DomainWorkspaceMetadata]
    let selectedID: UUID?
    let selectedName: String?
    let recentID: UUID?
    let isDisabled: (UUID) -> Bool
    let choose: (UUID?) -> Void
    let openFolder: () -> Void
    @State private var expanded = false
    @State private var search = ""
    @ObservedObject private var fonts = FontScaleManager.shared

    private var ordered: [DomainWorkspaceMetadata] {
        guard let recentID, let recent = projects.first(where: { $0.id == recentID }) else { return projects }
        return [recent] + projects.filter { $0.id != recentID }
    }

    private func label(_ project: DomainWorkspaceMetadata) -> String {
        project.name + (projects.count(where: { $0.name == project.name }) > 1 ? " · \(project.id.uuidString.prefix(8))" : "")
    }

    var body: some View {
        Menu {
            Section("Recent projects") {
                ForEach(Array(ordered.prefix(10)), id: \.id) { project in
                    Button(label(project)) { choose(project.id) }.disabled(isDisabled(project.id))
                }
            }
            Button("All projects…") { expanded = true }
            Divider()
            Button("Open Folder…", action: openFolder)
        } label: {
            Label(selectedName ?? projects.first(where: { $0.id == selectedID }).map(label) ?? "Choose project", systemImage: "folder")
                .font(fonts.preset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .lineLimit(1)
                // Match the native execution-location chip's label bound.
                .frame(maxWidth: fonts.preset.scaledClamped(170, max: 220), alignment: .leading)
                .padding(.horizontal, AgentPillMetrics.horizontalPadding())
                .frame(height: AgentPillMetrics.height())
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
        }.menuStyle(.borderlessButton).fixedSize()
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search projects…", text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(ordered.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.repoPaths.contains { $0.localizedCaseInsensitiveContains(search) } }, id: \.id) { project in
                                Button(label(project)) { choose(project.id)
                                    expanded = false
                                }.disabled(isDisabled(project.id))
                                    .buttonStyle(.plain).padding(.vertical, 5)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Open Folder…") { expanded = false
                        openFolder()
                    }
                }.padding().frame(width: 370, height: 400)
            }
    }
}
