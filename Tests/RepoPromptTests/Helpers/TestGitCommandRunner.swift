import Foundation

enum TestGitCommandRunner {
    enum GlobalConfig {
        case disabled
        case inherited
    }

    struct Environment {
        var globalConfig: GlobalConfig

        static let hermetic = Environment(globalConfig: .disabled)
        static let inheritedGlobalConfig = Environment(globalConfig: .inherited)
    }

    static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    static func processEnvironment(
        _ environment: Environment = .hermetic,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var processEnvironment = base
        processEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        if environment.globalConfig == .disabled {
            processEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        }
        processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        return processEnvironment
    }

    static func runResult(
        _ arguments: [String],
        cwd: URL,
        environment: Environment = .hermetic
    ) throws -> TestProcessResult {
        try TestProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: processEnvironment(environment)
        )
    }

    @discardableResult
    static func run(
        _ arguments: [String],
        cwd: URL,
        environment: Environment = .hermetic,
        failureDomain: String
    ) throws -> String {
        let result = try runResult(arguments, cwd: cwd, environment: environment)
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: failureDomain,
                code: Int(result.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: failureDescription(
                        arguments: arguments,
                        cwd: cwd,
                        outputText: result.outputText
                    )
                ]
            )
        }
        return result.outputText
    }

    static func failureDescription(arguments: [String], cwd: URL, outputText: String) -> String {
        "git \(arguments.joined(separator: " ")) failed in \(cwd.path): \(outputText)"
    }
}
