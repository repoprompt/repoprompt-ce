import Foundation

/// Reduces a single snapshot-poll batch to the latest state for entities whose
/// events are state projections. Lifecycle and interaction events remain
/// discrete so a client never loses an attention transition.
public enum RemoteEventCoalescer {
    private enum Key: Hashable {
        case authorization
        case catalog
        case workspace(String)
        case session(UUID)
        case transcript(UUID)
    }

    public static func coalesce(_ events: [RemoteEvent]) -> [RemoteEvent] {
        var result: [RemoteEvent] = []
        var indexes: [Key: Int] = [:]

        for event in events {
            guard let key = key(for: event) else {
                result.append(event)
                continue
            }

            if let index = indexes[key] {
                result[index] = event
            } else {
                indexes[key] = result.count
                result.append(event)
            }
        }
        return result
    }

    private static func key(for event: RemoteEvent) -> Key? {
        switch event.type {
        case .authorizationChanged:
            return .authorization
        case .catalogChanged:
            return .catalog
        case .workspaceOpening, .workspaceReady:
            guard let workspaceID = event.workspaceID else { return nil }
            return .workspace(workspaceID)
        case .sessionUpdated, .runProgressed:
            guard let sessionID = event.sessionID else { return nil }
            return .session(sessionID)
        case .transcriptItemsAppended:
            guard let sessionID = event.sessionID else { return nil }
            return .transcript(sessionID)
        default:
            return nil
        }
    }
}
