import Foundation
import MCP

enum CLIFormElicitationError: Error, Equatable, CustomStringConvertible {
    case invalidResponse

    var description: String {
        "Form elicitation response must be a JSON object, `decline`, or `cancel`."
    }
}

enum CLIFormElicitation {
    static func request(_ parameters: CreateElicitation.Parameters) async throws -> CreateElicitation.Result {
        guard case let .form(form) = parameters else {
            return CreateElicitation.Result(action: .cancel)
        }

        fputs("\n=== MCP Form Elicitation ===\n", stderr)
        fputs(form.message + "\n\n", stderr)
        fputs("Respond with the requested JSON object, `decline`, or `cancel`.\n> ", stderr)
        fflush(stderr)

        guard let response = readLine() else {
            return CreateElicitation.Result(action: .cancel)
        }
        return try parseResponse(response)
    }

    static func parseResponse(_ raw: String) throws -> CreateElicitation.Result {
        let response = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch response.lowercased() {
        case "decline":
            return CreateElicitation.Result(action: .decline)
        case "cancel":
            return CreateElicitation.Result(action: .cancel)
        default:
            guard let data = response.data(using: .utf8),
                  let content = try? JSONDecoder().decode([String: Value].self, from: data)
            else { throw CLIFormElicitationError.invalidResponse }
            return CreateElicitation.Result(action: .accept, content: content)
        }
    }
}
