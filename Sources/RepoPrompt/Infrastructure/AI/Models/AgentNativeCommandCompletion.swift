import Foundation

/// A provider-native terminal-final event, never inferred from an MCP tool's displayed name.
struct AgentNativeCommandCompletion {
    let invocationID: UUID
    let command: String?
    let argv: [String]?
    let exitCode: Int?
    let output: String?
    let isError: Bool
    let isTruncated: Bool

    static func decode(invocationID: UUID, argsJSON: String?, resultJSON: String, isError: Bool?) -> Self {
        func object(_ text: String?) -> [String: Any] {
            guard let text, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
        let args = object(argsJSON)
        let result = object(resultJSON)
        let command = (args["command"] as? String) ?? (args["cmd"] as? String)
        let argv = (args["command"] as? [String]) ?? (args["argv"] as? [String])
        return .init(
            invocationID: invocationID,
            command: command,
            argv: argv,
            exitCode: (result["exitCode"] as? Int) ?? (result["exit_code"] as? Int),
            output: (result["stdout"] as? String) ?? (result["aggregatedOutput"] as? String) ?? (result["output"] as? String),
            isError: isError == true,
            isTruncated: ["truncated", "isTruncated", "outputTruncated", "output_truncated", "summaryOnly", "summary_only"].contains { result[$0] as? Bool == true }
        )
    }
}
