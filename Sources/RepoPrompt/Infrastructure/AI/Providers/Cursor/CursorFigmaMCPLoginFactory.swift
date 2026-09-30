import Foundation

struct CursorFigmaMCPLoginPreflight: Equatable {
    let targetResolution: FigmaMCPProviderTargetResolution?
    let availability: FigmaMCPProviderLoginAvailability

    var permitsLogin: Bool {
        targetResolution.map { if case .resolved = $0 { true } else { false } } == true
            && availability == .available
    }
}

struct CursorFigmaMCPPreparedLoginAttempt: @unchecked Sendable {
    let providerTargetIdentifier: String
    let credentialContext: FigmaMCPProviderCredentialContext
    let evidence: FigmaMCPProviderCapabilityEvidence
    let launch: FigmaMCPProviderResolvedLoginLaunch
}

/// Provider-local construction seam for Cursor's Figma login path. This is deliberately limited to
/// Settings login and observation; it grants no proof, revocation, or runtime capability.
struct CursorFigmaMCPLoginComponents {
    let descriptor: CursorFigmaMCPLoginDescriptor
    let targetResolver: CursorFigmaMCPTargetResolver
    let subprocessDescriptor: FigmaMCPProviderSubprocessLoginDescriptor
    let executableVersionProbe: CursorExecutableVersionProbe
    let sessionController: FigmaMCPProviderTerminalHandoff.SessionController

    func makeLoginDriver(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environmentBuilder: @escaping FigmaMCPProviderSubprocessLoginDriver.EnvironmentBuilder = { request in
            await ProcessEnvironmentBuilder.build(request)
        },
        processRunner: FigmaMCPProviderSubprocessLoginDriver.ProcessRunner? = nil
    ) -> FigmaMCPProviderSubprocessLoginDriver {
        let versionProbe = executableVersionProbe
        return FigmaMCPProviderSubprocessLoginDriver(
            descriptor: subprocessDescriptor,
            inheritedEnvironment: inheritedEnvironment,
            environmentBuilder: environmentBuilder,
            executableVersionProbe: { executablePath, environment in
                await versionProbe.probe(executablePath: executablePath, environment: environment)
            },
            processRunner: processRunner ?? CursorFigmaTerminalHandoff.makeProcessRunner(
                sessionController: sessionController
            )
        )
    }

    func evaluatePreflight(
        using driver: FigmaMCPProviderSubprocessLoginDriver
    ) async -> CursorFigmaMCPLoginPreflight {
        guard hasReviewedGate, driver.runtimeProvider == .cursor, !Task.isCancelled else {
            return .init(targetResolution: nil, availability: .unavailable("Cursor Figma login is not supported by the reviewed capability gate."))
        }
        let resolution = await targetResolver.resolveTarget(for: .figma)
        guard !Task.isCancelled else {
            return .init(targetResolution: nil, availability: .unavailable("Cursor Figma login preflight was cancelled."))
        }
        guard case .resolved = resolution else {
            return .init(targetResolution: resolution, availability: Self.availability(for: resolution))
        }
        let availability = await driver.evaluateAvailability(provider: .cursor, target: .figma)
        guard !Task.isCancelled else {
            return .init(targetResolution: nil, availability: .unavailable("Cursor Figma login preflight was cancelled."))
        }
        return .init(targetResolution: resolution, availability: availability)
    }

    func prepareAttempt(
        _ attemptID: UUID,
        using driver: FigmaMCPProviderSubprocessLoginDriver
    ) async -> CursorFigmaMCPPreparedLoginAttempt? {
        guard hasReviewedGate, driver.runtimeProvider == .cursor, !Task.isCancelled else { return nil }
        let resolution = await targetResolver.resolveTarget(for: .figma)
        guard !Task.isCancelled,
              case let .resolved(identifier, source, credentialContext) = resolution,
              source == .providerStandardUserMetadata
        else { return nil }
        let launch = await driver.prepareAttempt(attemptID, credentialContext: credentialContext)
        guard !Task.isCancelled, let launch else { return nil }
        return .init(
            providerTargetIdentifier: identifier,
            credentialContext: credentialContext,
            evidence: descriptor.evidence,
            launch: launch
        )
    }

    private var hasReviewedGate: Bool {
        descriptor.provider == .cursor
            && descriptor.evidence.provider == .cursor
            && descriptor.evidence.evidenceID == CursorFigmaMCPLoginDescriptor.evidenceID
            && descriptor.evidence.capabilityRevision == CursorFigmaMCPLoginDescriptor.capabilityRevision
            && subprocessDescriptor.provider == .cursor
            && subprocessDescriptor.requiredExecutableVersion == CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild
    }

    private static func availability(
        for resolution: FigmaMCPProviderTargetResolution
    ) -> FigmaMCPProviderLoginAvailability {
        switch resolution {
        case .resolved:
            .available
        case let .missing(reason):
            .missingTarget(reason)
        case let .ambiguous(matchCount):
            .ambiguousTarget(matchCount)
        case let .untrustedCredentialContext(reason):
            .untrustedCredentialContext(reason)
        }
    }
}

enum CursorFigmaMCPLoginFactory {
    static func makeComponents(
        sessionController: FigmaMCPProviderTerminalHandoff.SessionController,
        configURL: URL? = nil,
        targetDataLoader: CursorFigmaMCPTargetResolver.DataLoader? = nil,
        timeout: TimeInterval = 5 * 60,
        executableVersionProbe: CursorExecutableVersionProbe? = nil
    ) -> CursorFigmaMCPLoginComponents {
        let descriptor = CursorFigmaMCPLoginDescriptor()
        let targetResolver = if let targetDataLoader {
            CursorFigmaMCPTargetResolver(configURL: configURL, dataLoader: targetDataLoader)
        } else {
            CursorFigmaMCPTargetResolver(configURL: configURL)
        }
        return CursorFigmaMCPLoginComponents(
            descriptor: descriptor,
            targetResolver: targetResolver,
            subprocessDescriptor: FigmaMCPProviderSubprocessLoginDescriptor(
                provider: descriptor.provider,
                command: descriptor.executableProfile.commandName,
                additionalPaths: descriptor.executableProfile.supplementalSearchPaths,
                timeout: timeout,
                requiredExecutableVersion: CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild,
                arguments: { targetIdentifier in
                    CursorFigmaMCPLoginDescriptor().loginArguments(targetIdentifier: targetIdentifier)
                }
            ),
            executableVersionProbe: executableVersionProbe ?? CursorExecutableVersionProbe(),
            sessionController: sessionController
        )
    }
}
