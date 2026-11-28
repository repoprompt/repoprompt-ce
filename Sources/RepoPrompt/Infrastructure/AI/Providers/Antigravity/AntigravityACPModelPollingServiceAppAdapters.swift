import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptProcess

extension AntigravityACPModelPollingService.RefreshOutcome {
    var connectionError: String? {
        switch self {
        case .connected, .cancelled:
            nil
        case .noModels, .signInRequired:
            "No models received. Confirm your Google sign-in, then test again."
        case let .failed(error):
            AntigravityLaunchDiagnostic.message(for: error) ?? "Antigravity could not complete model discovery. Try again."
        }
    }
}

/// Only expose local, typed launch diagnostics, never raw ACP server messages or stderr.
enum AntigravityLaunchDiagnostic {
    static func message(for error: any Error) -> String? {
        switch error {
        case let error as ExecutableFileIdentityError:
            error.localizedDescription
        case let error as ProcessLauncherError:
            processFailure(error)
        case let error as ProviderProcessLaunchPolicy.Refusal:
            error.localizedDescription
        case let AIProviderError.invalidConfiguration(detail):
            detail
        default:
            nil
        }
    }

    private static func processFailure(_ error: ProcessLauncherError) -> String {
        let failure = error.processLaunchFailure
        let reason = NSError(domain: failure.domain, code: failure.code).localizedDescription
        return "Could not start Antigravity: \(reason)"
    }
}

extension AntigravityACPModelPollingService {
    static let shared = AntigravityACPModelPollingService(
        client: AntigravityACPControllerModelDiscoveryClient(),
        registry: AgentModelCatalogRuntime.shared.acpRegistry,
        logFailure: { message in
            if AgentRuntimeProviderService.enableDebugLogging {
                print("[AntigravityACPModelPolling] refresh failed: \(message)")
            }
        }
    )
}
