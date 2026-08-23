import Foundation

/// Desktop `ToolAvailabilityStore` UserDefaults `mcp.disabledTools`.
/// Missing key → empty set (all tools enabled).
public struct MCPDisabledToolsSettings: Codable, Hashable, Sendable {
    public var disabledTools: Set<String>

    public init(disabledTools: Set<String> = []) {
        self.disabledTools = disabledTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabledTools = try container.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? []
    }

    public func isEnabled(_ name: String) -> Bool {
        !disabledTools.contains(name)
    }

    /// Desktop `ToolAvailabilityStore.toggle`.
    public mutating func setToolEnabled(_ name: String, enabled: Bool) {
        if enabled {
            disabledTools.remove(name)
        } else {
            disabledTools.insert(name)
        }
    }

    /// Desktop first discovery of `isEnabledByDefault == false` inserts the name.
    @discardableResult
    public mutating func applyDefaultOffDiscoveries(_ names: Set<String>) -> Bool {
        var changed = false
        for name in names where !disabledTools.contains(name) {
            disabledTools.insert(name)
            changed = true
        }
        return changed
    }
}

public struct MCPDisabledToolsSettingsSnapshot: Codable, Hashable, Sendable {
    public let settings: MCPDisabledToolsSettings
    public let revision: Int64
    public let updatedAt: Date

    public init(settings: MCPDisabledToolsSettings, revision: Int64, updatedAt: Date) {
        self.settings = settings
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct ReplaceMCPDisabledToolsSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let settings: MCPDisabledToolsSettings

    public init(expectedRevision: Int64, settings: MCPDisabledToolsSettings) {
        self.expectedRevision = expectedRevision
        self.settings = settings
    }
}
