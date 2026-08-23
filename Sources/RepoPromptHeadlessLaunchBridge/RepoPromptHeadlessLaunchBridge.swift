import Darwin
import Foundation

public enum RepoPromptHeadlessLaunchBridgeError: Error, CustomStringConvertible {
    case helperMissing
    case helperNotExecutable
    case incompatibleContract(String)
    case invalidArchitecture(String)
    case invalidSignature
    case processReplacementFailed(Int32)

    public var description: String {
        switch self {
        case .helperMissing: "private headless runtime helper is missing"
        case .helperNotExecutable: "private headless runtime helper is not executable"
        case let .incompatibleContract(value): "private headless runtime contract is incompatible (\(value))"
        case let .invalidArchitecture(value): "private headless runtime architecture is incompatible (\(value))"
        case .invalidSignature: "private headless runtime signature validation failed"
        case let .processReplacementFailed(code): "private headless runtime launch failed (errno \(code))"
        }
    }
}

public enum RepoPromptHeadlessLaunchBridge {
    public static let contractVersion = "1"
    public static let helperName = "repoprompt-mcp-headless-runtime"

    public static func resolvedHelper(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL
    ) throws -> URL {
        if environment["REPOPROMPT_MCP_HEADLESS_RUNTIME_TEST_OVERRIDE_ALLOWED"] == "1",
           let override = environment["REPOPROMPT_MCP_HEADLESS_RUNTIME_EXECUTABLE"],
           override.hasPrefix("/")
        {
            return try validate(URL(fileURLWithPath: override), packaged: false)
        }
        guard let executableURL else { throw RepoPromptHeadlessLaunchBridgeError.helperMissing }
        let adjacent = executableURL.deletingLastPathComponent().appendingPathComponent(helperName)
        if FileManager.default.fileExists(atPath: adjacent.path) {
            return try validate(adjacent, packaged: false)
        }
        let macOSDirectory = executableURL.deletingLastPathComponent()
        let bundled = macOSDirectory.deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperName)
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            throw RepoPromptHeadlessLaunchBridgeError.helperMissing
        }
        return try validate(bundled, packaged: true)
    }

    public static func replaceCurrentProcess(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Never {
        let helper = try resolvedHelper(environment: environment)
        let values = [helper.path, "--launcher-contract-version", contractVersion] + Array(arguments.dropFirst())
        let storage = values.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var argv = storage + [nil]
        execv(helper.path, &argv)
        throw RepoPromptHeadlessLaunchBridgeError.processReplacementFailed(errno)
    }

    private static func validate(_ helper: URL, packaged: Bool) throws -> URL {
        var information = stat()
        guard lstat(helper.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: helper.path)
        else {
            throw RepoPromptHeadlessLaunchBridgeError.helperNotExecutable
        }
        let contract = try command(helper.path, ["--print-launcher-contract-version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard contract == contractVersion else {
            throw RepoPromptHeadlessLaunchBridgeError.incompatibleContract(contract)
        }
        #if arch(arm64)
        let requiredArchitecture = "arm64"
        #elseif arch(x86_64)
        let requiredArchitecture = "x86_64"
        #else
        let requiredArchitecture = ""
        #endif
        if !requiredArchitecture.isEmpty {
            let architectures = try command("/usr/bin/lipo", ["-archs", helper.path])
            guard architectures.split(whereSeparator: \.isWhitespace).contains(Substring(requiredArchitecture)) else {
                throw RepoPromptHeadlessLaunchBridgeError.invalidArchitecture(architectures)
            }
        }
        if packaged {
            let result = try commandResult("/usr/bin/codesign", ["--verify", "--strict", helper.path])
            guard result.status == 0 else { throw RepoPromptHeadlessLaunchBridgeError.invalidSignature }
        }
        return helper
    }

    private static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try commandResult(executable, arguments)
        guard result.status == 0 else {
            throw RepoPromptHeadlessLaunchBridgeError.incompatibleContract(result.output)
        }
        return result.output
    }

    private static func commandResult(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
