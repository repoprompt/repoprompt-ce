#if DEBUG
    import Foundation

    enum GitWorktreeRetirementDebugLaunchActivation {
        static let environmentKey = "REPOPROMPT_DEBUG_WORKTREE_RETIREMENT_POLICY_RECEIPT"
        static let requiredReceipt = "repoprompt-ce.authoritative-worktree-retirement.debug.v1"

        enum Outcome: Equatable {
            case notRequested
            case activated
            case alreadyActivated
            case refused
        }

        private struct LaunchEnvironmentPolicyAuthority: GitWorktreeRetirementOperatorPolicyAuthority {
            func validateRetirementPolicyReceipt(
                _ receipt: Data,
                policyVersion: Int
            ) throws -> GitWorktreeRetirementPolicyValidation {
                guard policyVersion == GitWorktreeRetirementActivation.requiredPolicyVersion,
                      receipt == Data(GitWorktreeRetirementDebugLaunchActivation.requiredReceipt.utf8)
                else {
                    throw GitWorktreeRetirementActivationInstallationError.invalidReceipt
                }
                return GitWorktreeRetirementPolicyValidation(
                    authorityID: "repoprompt-ce.debug-launch-environment",
                    receiptID: "authoritative-worktree-retirement.debug.v1",
                    approvedAt: Date()
                )
            }
        }

        @discardableResult
        static func installIfRequested(environment: [String: String]) -> Outcome {
            guard let receipt = environment[environmentKey], !receipt.isEmpty else {
                return .notRequested
            }
            do {
                try GitWorktreeRetirementActivation.install(
                    policyVersion: GitWorktreeRetirementActivation.requiredPolicyVersion,
                    receipt: Data(receipt.utf8),
                    authority: LaunchEnvironmentPolicyAuthority()
                )
                return .activated
            } catch GitWorktreeRetirementActivationInstallationError.alreadyInstalled {
                return .alreadyActivated
            } catch {
                return .refused
            }
        }
    }
#endif
