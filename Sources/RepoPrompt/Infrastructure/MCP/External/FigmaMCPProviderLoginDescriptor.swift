import Foundation

struct FigmaMCPProviderLoginLaunchSpec: Equatable {
    let provider: ExternalMCPRuntimeProvider
    let executable: CLILaunchProfile
    let arguments: [String]
    let targetIdentifier: String
    let evidence: FigmaMCPProviderCapabilityEvidence
    let minimumSupportedVersion: String?

    var minimumSupportedExecutableVersion: String? {
        minimumSupportedVersion
    }

    init(
        provider: ExternalMCPRuntimeProvider,
        executable: CLILaunchProfile,
        arguments: [String],
        targetIdentifier: String,
        evidence: FigmaMCPProviderCapabilityEvidence,
        minimumSupportedVersion: String? = nil
    ) {
        self.provider = provider
        self.executable = executable
        self.arguments = arguments
        self.targetIdentifier = targetIdentifier
        self.evidence = evidence
        self.minimumSupportedVersion = minimumSupportedVersion
    }
}

protocol FigmaMCPProviderLoginDescribing {
    var provider: ExternalMCPRuntimeProvider { get }
    var evidence: FigmaMCPProviderCapabilityEvidence { get }
    var executableProfile: CLILaunchProfile { get }
    var minimumSupportedVersion: String? { get }
    func loginArguments(targetIdentifier: String) -> [String]
}

extension FigmaMCPProviderLoginDescribing {
    func launchSpec(targetIdentifier: String) -> FigmaMCPProviderLoginLaunchSpec {
        FigmaMCPProviderLoginLaunchSpec(
            provider: provider,
            executable: executableProfile,
            arguments: loginArguments(targetIdentifier: targetIdentifier),
            targetIdentifier: targetIdentifier,
            evidence: evidence,
            minimumSupportedVersion: minimumSupportedVersion
        )
    }

    /// Executable identity and version probing remain owned by the provider launch resolver;
    /// this gate only applies the descriptor's recorded minimum when one exists.
    func isSupportedVersion(_ version: String?) -> Bool {
        guard let version, let parsed = FigmaMCPProviderVersion(version) else { return false }
        guard let minimumSupportedVersion else { return true }
        guard let minimum = FigmaMCPProviderVersion(minimumSupportedVersion) else { return false }
        return parsed >= minimum
    }
}

private struct FigmaMCPProviderVersion: Comparable {
    let components: [Int]

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        components = values
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        zip(lhs.components, rhs.components).first { $0 != $1 }.map { $0.0 < $0.1 } ?? false
    }
}
