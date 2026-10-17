import MCP
import RepoPromptShared

/// Single source for the app-backed long-running ticket contract advertised by `ask_oracle`,
/// `oracle_send`, and `context_builder`. Providers must not restate it: the canonical
/// definition replaces provider descriptions and schemas at binding time.
package enum MCPLongRunningJobToolContract {
    static let usageContract = "For app-backed long work use op=start, detach=true, then op=poll|wait|cancel with the returned job_id. job_id is a job UUID, not a chat or session ID. timeout bounds observation, not execution: an observation timeout does not stop the job. Jobs survive client disconnect, but not app restart; retained tickets can expire. Omit op for unchanged legacy blocking execution. A non-detached start waits only for the observation interval before returning a snapshot. Direct-headless execution rejects ticket arguments."
    static let askOracleGuidance = usageContract
    static let oracleSendGuidance = usageContract + " Terminal payload preserves existing fields and adds job/job_id; lane progress contains statuses, not early responses."
    static let contextBuilderGuidance = usageContract + " One job owns discovery, optional Oracle follow-up and export."

    package static let operationDescription = "App-backed ticket operation. Direct headless rejects ticket arguments. Omit for unchanged blocking execution."
    package static let jobIDDescription = "Job UUID for poll/wait/cancel, not a chat/session ID"
    package static let detachDescription = "start only: return immediately after admission"
    package static let timeoutDescription = "start/wait observation seconds, using agent_run timeout policy; omitted timeout uses the \(MCPTimeoutPolicy.configuredSubagentWaitDiscoveryPhrase). Observation timeout does not stop execution."

    static var properties: [String: Value] {
        [
            "op": .object([
                "type": .string("string"),
                "enum": .array(["start", "poll", "wait", "cancel"].map(Value.string)),
                "description": .string(operationDescription)
            ]),
            "job_id": .object([
                "type": .string("string"),
                "description": .string(jobIDDescription)
            ]),
            "detach": .object([
                "type": .string("boolean"),
                "description": .string(detachDescription)
            ]),
            "timeout": .object([
                "type": .string("number"),
                "description": .string(timeoutDescription)
            ])
        ]
    }
}
