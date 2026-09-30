import Foundation

/// Compatibility conformance keeps app-wide settings ownership in GlobalSettingsStore while
/// allowing neutral coordinators to depend on a narrow protocol.
extension GlobalSettingsStore: ExternalMCPIntegrationSettingsStore {}
