#if os(Linux)
    import Foundation
    import Glibc
    import RepoPromptShared

    @main
    struct RepoPromptLinuxHeadlessMain {
        static func main() async {
            _ = signal(SIGPIPE, SIG_IGN)

            do {
                let arguments = Array(CommandLine.arguments.dropFirst())
                if DirectHeadlessChildBridge.isRequested(), isServeCommand(arguments) {
                    try await DirectHeadlessChildBridge.run()
                    return
                }

                switch try command(from: arguments) {
                case .serve:
                    try await DirectHeadlessMCPService().run()
                case .help:
                    FileHandle.standardOutput.write(Data((usage + "\n").utf8))
                case .version:
                    print("repoprompt-mcp \(CLI_VERSION)")
                }
            } catch let error as ArgumentError {
                _ = BestEffortStderrWriter.write(Data("Error: \(error.description)\n\(usage)\n".utf8))
                exit(2)
            } catch {
                _ = BestEffortStderrWriter.write(Data("RepoPrompt MCP headless: \(error)\n".utf8))
                exit(1)
            }
        }

        private enum Command {
            case serve
            case help
            case version
        }

        private enum ArgumentError: Error, CustomStringConvertible {
            case explicitHeadlessBackendRequired
            case unsupportedBackend(String)
            case unsupportedArguments([String])

            var description: String {
                switch self {
                case .explicitHeadlessBackendRequired:
                    "Linux requires the explicit '--backend headless' mode."
                case let .unsupportedBackend(backend):
                    "Linux does not provide the '\(backend)' backend; use '--backend headless'."
                case let .unsupportedArguments(arguments):
                    "unsupported Linux headless arguments: \(arguments.joined(separator: " "))"
                }
            }
        }

        private static func isServeCommand(_ arguments: [String]) -> Bool {
            arguments == ["--backend", "headless"] || arguments == ["--backend=headless"]
        }

        private static func command(from arguments: [String]) throws -> Command {
            if arguments == ["--backend", "headless"] || arguments == ["--backend=headless"] {
                return .serve
            }
            if arguments == ["--help"] || arguments == ["-h"] { return .help }
            if arguments == ["--version"] { return .version }
            if arguments.isEmpty { throw ArgumentError.explicitHeadlessBackendRequired }
            if arguments.count == 2, arguments[0] == "--backend" {
                throw ArgumentError.unsupportedBackend(arguments[1])
            }
            if arguments.count == 1, arguments[0].hasPrefix("--backend=") {
                throw ArgumentError.unsupportedBackend(String(arguments[0].dropFirst("--backend=".count)))
            }
            throw ArgumentError.unsupportedArguments(arguments)
        }

        private static let usage = """
        Usage: repoprompt-mcp --backend headless

        Linux packages the upstream direct headless MCP backend only. App proxy,
        auto-probe, interactive, and exec modes remain macOS-only.
        """
    }
#endif
