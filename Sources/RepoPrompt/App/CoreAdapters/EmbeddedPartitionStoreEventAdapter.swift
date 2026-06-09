import Foundation
import RepoPromptCore

enum EmbeddedPartitionStoreEventAdapter {
    static let didSaveNotification = Notification.Name("RepoPrompt.PartitionStoreDidSave")
    static let rootPathKey = "rootPath"
    static let workspaceIDKey = "workspaceID"
    static let tabIDKey = "tabID"
    static let sourceIDKey = "sourceID"

    static let sink: PartitionStoreSaveEventSink = { event in
        NotificationCenter.default.post(
            name: didSaveNotification,
            object: nil,
            userInfo: [
                rootPathKey: event.rootPath,
                workspaceIDKey: event.scope.workspaceID,
                tabIDKey: event.scope.tabID as Any,
                sourceIDKey: event.sourceID
            ]
        )
    }
}
