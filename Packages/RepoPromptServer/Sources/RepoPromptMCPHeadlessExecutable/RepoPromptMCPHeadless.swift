#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import RepoPromptMCPAdapter
import RepoPromptServerHost

let HEADLESS_CLI_VERSION = "1.3.0"
let HEADLESS_LAUNCHER_CONTRACT_VERSION = "1"

@main
enum RepoPromptMCPHeadlessBootstrap {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--print-launcher-contract-version" {
            print(HEADLESS_LAUNCHER_CONTRACT_VERSION)
            return
        }
        guard let index = arguments.firstIndex(of: "--launcher-contract-version"),
              arguments.indices.contains(index + 1),
              arguments[index + 1] == HEADLESS_LAUNCHER_CONTRACT_VERSION
        else {
            FileHandle.standardError.write(
                Data("RepoPrompt private headless runtime: incompatible or missing launcher contract\n".utf8)
            )
            exit(64)
        }
        do {
            if RepoPromptDirectHeadlessChildBridgeRunner.isRequested() {
                try await RepoPromptDirectHeadlessChildBridgeRunner.run()
                return
            }
            let host = try await RepoPromptDirectHeadlessComposition.start()
            try await run(host: host)
        } catch {
            FileHandle.standardError.write(Data("RepoPrompt private headless runtime: \(error)\n".utf8))
            exit(70)
        }
    }

    static func run(
        host: any RepoPromptMCPHeadlessHosting,
        execute: @escaping @Sendable (
            _ adapter: RepoPromptMCPAdapter,
            _ binding: RepoPromptMCPBinding,
            _ isRootSession: Bool
        ) async throws -> Void = { adapter, binding, isRootSession in
            try await RepoPromptMCPStdioExecution.run(
                adapter: adapter,
                binding: binding,
                isRootSession: isRootSession,
                policyProfile: .direct
            )
        }
    ) async throws {
        let adapter = RepoPromptMCPAdapter(serving: host.serving)
        do {
            try await execute(adapter, host.binding, host.isRootSession)
            await host.shutdown()
        } catch {
            await host.shutdown()
            throw error
        }
    }
}

protocol RepoPromptMCPHeadlessHosting: Sendable {
    var serving: any RepoPromptMCPServingCapability { get }
    var binding: RepoPromptMCPBinding { get }
    var isRootSession: Bool { get }

    func shutdown() async
}

extension RepoPromptDirectHeadlessComposition: RepoPromptMCPHeadlessHosting {}
