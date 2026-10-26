import Foundation
import RepoPromptDomainRuntime

extension DebugStateBootstrap.Builder {
    /// Walk only Agent session schema carriers. Text, tool payloads, tagged repository
    /// files, remote URLs and external local attachments are never rewritten.
    func rebaseManagedAttachments(in document: [String: Any]) throws -> [String: Any] {
        func attachments(in record: [String: Any]) throws -> [String: Any] {
            guard let values = record["attachments"] as? [[String: Any]] else { return record }
            var copy = record
            copy["attachments"] = try values.map { value -> [String: Any] in
                let attachment = try JSONDecoder().decode(AgentImageAttachment.self, from: json(value))
                guard case let .localFile(path) = attachment.source, path.hasPrefix("/") else { return value }
                let candidate = URL(fileURLWithPath: path).standardizedFileURL
                for (source, destination) in mappings where destination.pathComponents.starts(with: locations.workspaceRoot.pathComponents) {
                    let managed = AgentAttachmentStore.managedStorageRootURL(for: source)
                    guard candidate.pathComponents.starts(with: managed.pathComponents), candidate.path != managed.path else { continue }
                    let targetRoot = AgentAttachmentStore.managedStorageRootURL(for: destination)
                    let target = candidate.pathComponents.dropFirst(managed.pathComponents.count).reduce(targetRoot) { $0.appendingPathComponent($1) }
                    var copy = value
                    // Re-encode only the typed source field; preserve all other/unknown fields.
                    copy["source"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentImageSource.localFile(path: target.path)))
                    return copy
                }
                return value
            }
            return copy
        }
        var copy = document
        if let items = document["items"] as? [[String: Any]] { copy["items"] = try items.map { try attachments(in: $0) } }
        if var transcript = document["transcript"] as? [String: Any], let turns = transcript["turns"] as? [[String: Any]] {
            transcript["turns"] = try turns.map { turn -> [String: Any] in
                var result = turn
                if let request = turn["request"] as? [String: Any] { result["request"] = try attachments(in: request) }
                if let spans = turn["responseSpans"] as? [[String: Any]] {
                    result["responseSpans"] = try spans.map { span -> [String: Any] in
                        var result = span
                        if let activities = span["activities"] as? [[String: Any]] {
                            result["activities"] = try activities.map { try attachments(in: $0) }
                        }
                        return result
                    }
                }
                return result
            }
            copy["transcript"] = transcript
        }
        return copy
    }
}
