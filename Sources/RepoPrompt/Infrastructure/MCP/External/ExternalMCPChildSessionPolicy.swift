import Foundation

/// Explicit inheritance result for every runtime session class. The conservative default is
/// denied; a provider adapter must opt in with tested semantics before a child is bound.
enum ExternalMCPChildSessionAccess: String, Codable, Equatable {
    case allowed
    case denied
    case unsupported
    case providerOwned
}

struct ExternalMCPChildSessionPolicy: Codable, Equatable {
    let topLevel: ExternalMCPChildSessionAccess
    let managedChild: ExternalMCPChildSessionAccess
    let providerNativeChild: ExternalMCPChildSessionAccess
    let headless: ExternalMCPChildSessionAccess
    let cloudChild: ExternalMCPChildSessionAccess
    let discovery: ExternalMCPChildSessionAccess

    init(
        topLevel: ExternalMCPChildSessionAccess = .denied,
        managedChild: ExternalMCPChildSessionAccess = .denied,
        providerNativeChild: ExternalMCPChildSessionAccess = .denied,
        headless: ExternalMCPChildSessionAccess = .denied,
        cloudChild: ExternalMCPChildSessionAccess = .denied,
        discovery: ExternalMCPChildSessionAccess = .denied
    ) {
        self.topLevel = topLevel
        self.managedChild = managedChild
        self.providerNativeChild = providerNativeChild
        self.headless = headless
        self.cloudChild = cloudChild
        self.discovery = discovery
    }

    static let denyByDefault = Self()

    func access(for sessionClass: ExternalMCPSessionClass) -> ExternalMCPChildSessionAccess {
        switch sessionClass {
        case .topLevel: topLevel
        case .managedChild: managedChild
        case .providerNativeChild: providerNativeChild
        case .headless: headless
        case .cloudChild: cloudChild
        case .discovery: discovery
        }
    }
}
