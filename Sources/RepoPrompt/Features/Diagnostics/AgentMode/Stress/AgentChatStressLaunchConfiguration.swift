#if DEBUG
    import CoreGraphics
    import Foundation

    /// Launch configuration for the DEBUG-only Agent chat stress harness.
    ///
    /// The harness stays off unless the debug app is launched with the `-RP_AGENT_CHAT_STRESS`
    /// argument. Environment variables (all optional):
    /// - `RP_AGENT_STRESS_SCENARIO`: one of `Scenario`'s raw values (default `mixedToolLoop`).
    /// - `RP_AGENT_STRESS_AUTO_START`, `RP_AGENT_STRESS_SHOW_OVERLAY`: booleans (default on).
    /// - `RP_AGENT_STRESS_INTERVAL_MS`, `RP_AGENT_STRESS_WARMUP_TURNS`, `RP_AGENT_STRESS_TOOL_STEP_REPEAT`,
    ///   `RP_AGENT_STRESS_REFRESH_POLICY`, `RP_AGENT_STRESS_MAX_LOG_ENTRIES`: scenario pacing.
    /// - `RP_AGENT_STRESS_CATASTROPHIC_JUMP_POINTS`, `RP_AGENT_STRESS_CATASTROPHIC_EXPOSURE_BLOCKS`: thresholds.
    /// - `RP_AGENT_STRESS_WORKSPACE_NAME`, `RP_AGENT_STRESS_WORKSPACE_ROOT(S)`,
    ///   `RP_AGENT_STRESS_CREATE_WORKSPACE_IF_NEEDED`, `RP_AGENT_STRESS_ALLOW_SESSION_PERSISTENCE`: workspace setup.
    /// - `RP_AGENT_STRESS_AGENT_SESSION_FIXTURE`: fixture name for `persistedAgentSessionFixture`.
    /// - `RP_AGENT_STRESS_RESTORED_TURNS`: fast path for large-session runs. Number of synthetic
    ///   historical turns staged as a persisted session before `persistedCodexReplayChurn` starts
    ///   streaming (clamped to 1...5000; default `max(8, warmupTurns * 3)`). For example
    ///   `RP_AGENT_STRESS_SCENARIO=persistedCodexReplayChurn RP_AGENT_STRESS_RESTORED_TURNS=1000`
    ///   restores a 1000-turn session and then streams into it.
    /// - `RP_AGENT_STRESS_TRACK_READING_POSITION`: boolean (default on). Enables the per-block
    ///   geometry probe behind `positionShiftWhileReadingCount`; turn it off for frame-interval-only
    ///   runs because the probe itself adds per-block geometry callbacks.
    struct AgentChatStressLaunchConfiguration: Equatable {
        enum Scenario: String, Equatable {
            case mixedToolLoop
            case richToolChurn
            case assistantMarkdownChurn
            case assistantMarkdownMegaChurn
            case persistedCodexReplayChurn
            case persistedAgentSessionFixture

            var requiresPersistedSessionRestore: Bool {
                switch self {
                case .persistedCodexReplayChurn, .persistedAgentSessionFixture:
                    true
                case .mixedToolLoop, .richToolChurn, .assistantMarkdownChurn, .assistantMarkdownMegaChurn:
                    false
                }
            }
        }

        enum MutationRefreshPolicy: String, Equatable {
            case urgentPerMutation
            case deferred
        }

        let autoStart: Bool
        let showOverlay: Bool
        let scenario: Scenario
        let insertionInterval: TimeInterval
        let warmupTurnCount: Int
        let toolStepRepeatCount: Int
        let mutationRefreshPolicy: MutationRefreshPolicy
        let maxVisibleEventLogEntries: Int
        let catastrophicJumpThresholdPoints: CGFloat
        let catastrophicHistoricalExposureBlockThreshold: Int
        let workspaceName: String?
        let workspaceRootPaths: [String]
        let createsWorkspaceIfNeeded: Bool
        let allowsAgentSessionPersistence: Bool
        let agentSessionFixtureName: String?
        let restoredTurnCountOverride: Int?
        let tracksReadingPosition: Bool

        /// Historical turns staged by the persisted Codex replay scenario before streaming starts.
        var restoredTurnCount: Int {
            restoredTurnCountOverride ?? max(8, warmupTurnCount * 3)
        }

        init(environment: [String: String]) {
            autoStart = Self.boolValue(environment["RP_AGENT_STRESS_AUTO_START"], default: true)
            showOverlay = Self.boolValue(environment["RP_AGENT_STRESS_SHOW_OVERLAY"], default: true)
            scenario = Scenario(rawValue: environment["RP_AGENT_STRESS_SCENARIO"] ?? "") ?? .mixedToolLoop
            insertionInterval = max(0.05, Double(environment["RP_AGENT_STRESS_INTERVAL_MS"] ?? "120").map { $0 / 1000.0 } ?? 0.12)
            warmupTurnCount = max(1, Int(environment["RP_AGENT_STRESS_WARMUP_TURNS"] ?? "4") ?? 4)
            toolStepRepeatCount = min(8, max(1, Int(environment["RP_AGENT_STRESS_TOOL_STEP_REPEAT"] ?? "1") ?? 1))
            mutationRefreshPolicy = MutationRefreshPolicy(rawValue: environment["RP_AGENT_STRESS_REFRESH_POLICY"] ?? "") ?? .urgentPerMutation
            maxVisibleEventLogEntries = max(5, Int(environment["RP_AGENT_STRESS_MAX_LOG_ENTRIES"] ?? "24") ?? 24)
            catastrophicJumpThresholdPoints = max(80, Double(environment["RP_AGENT_STRESS_CATASTROPHIC_JUMP_POINTS"] ?? "220").map { CGFloat($0) } ?? 220)
            catastrophicHistoricalExposureBlockThreshold = max(4, Int(environment["RP_AGENT_STRESS_CATASTROPHIC_EXPOSURE_BLOCKS"] ?? "10") ?? 10)
            workspaceName = Self.normalizedString(environment["RP_AGENT_STRESS_WORKSPACE_NAME"])
            workspaceRootPaths = Self.pathListValue(
                environment["RP_AGENT_STRESS_WORKSPACE_ROOTS"] ?? environment["RP_AGENT_STRESS_WORKSPACE_ROOT"]
            )
            createsWorkspaceIfNeeded = Self.boolValue(
                environment["RP_AGENT_STRESS_CREATE_WORKSPACE_IF_NEEDED"],
                default: workspaceName != nil && !workspaceRootPaths.isEmpty
            )
            allowsAgentSessionPersistence = Self.boolValue(
                environment["RP_AGENT_STRESS_ALLOW_SESSION_PERSISTENCE"],
                default: scenario.requiresPersistedSessionRestore
            )
            agentSessionFixtureName = Self.normalizedString(environment["RP_AGENT_STRESS_AGENT_SESSION_FIXTURE"])
                ?? (
                    scenario == .persistedAgentSessionFixture
                        ? "review-idle-scroll-coalescing-fix-97A6BA23.json"
                        : nil
                )
            restoredTurnCountOverride = Self.normalizedString(environment["RP_AGENT_STRESS_RESTORED_TURNS"])
                .flatMap { Int($0) }
                .map { min(5000, max(1, $0)) }
            tracksReadingPosition = Self.boolValue(environment["RP_AGENT_STRESS_TRACK_READING_POSITION"], default: true)
        }

        private static func boolValue(_ raw: String?, default defaultValue: Bool) -> Bool {
            guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
                return defaultValue
            }
            switch normalized {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return defaultValue
            }
        }

        private static func normalizedString(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        private static func pathListValue(_ raw: String?) -> [String] {
            guard let raw else { return [] }
            return raw
                .split(whereSeparator: { $0 == "\n" || $0 == ";" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
#endif
