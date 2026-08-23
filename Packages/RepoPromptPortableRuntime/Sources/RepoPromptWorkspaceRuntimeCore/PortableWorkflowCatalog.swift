import RepoPromptShared

public struct PortableWorkflowDescriptor: Equatable, Sendable {
    public let id: RepoPromptWorkflowID
    public let commandName: String
    public let prompt: String

    public init(id: RepoPromptWorkflowID, commandName: String, prompt: String) {
        self.id = id
        self.commandName = commandName
        self.prompt = prompt
    }
}

public enum PortableWorkflowCatalog {
    public static let descriptors: [PortableWorkflowDescriptor] = RepoPromptWorkflowID.installOrder.map { id in
        PortableWorkflowDescriptor(
            id: id,
            commandName: id.commandName,
            prompt: RepoPromptWorkflowPrompts.render(id: id, variant: .agent)
        )
    }
}
