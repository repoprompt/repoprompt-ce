import Darwin
import Foundation
import RepoPromptDomainRuntime

enum RuntimePolicyAdministration {
    enum CommandError: Error, LocalizedError {
        case ttyRequired
        case invalidArguments(String)
        case confirmationDeclined

        var errorDescription: String? {
            switch self {
            case .ttyRequired:
                "Policy administration requires interactive stdin and stderr TTYs."
            case let .invalidArguments(message):
                message
            case .confirmationDeclined:
                "Policy change was not confirmed."
            }
        }
    }

    static func run(arguments: [String]) async -> Int32 {
        do {
            guard isatty(STDIN_FILENO) != 0, isatty(STDERR_FILENO) != 0 else {
                throw CommandError.ttyRequired
            }
            guard let command = arguments.first else {
                throw CommandError.invalidArguments(usage)
            }
            let store = makeRuntime().mutationPolicyStore
            let administrator = DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "tty:\(getuid())",
                displayName: "Local TTY administrator",
                kind: .ttyAdministrator,
                assurance: .localTTY,
                processID: getpid(),
                runID: nil,
                provider: nil
            )
            switch command {
            case "list":
                let (document, health) = await store.snapshot()
                let payload: [String: Any] = [
                    "version": document.version,
                    "revision": document.revision,
                    "health": String(describing: health),
                    "grants": document.headlessGrants.map { grant in
                        [
                            "id": grant.id.uuidString,
                            "principal": grant.principalKey,
                            "operations": grant.allowedOperations.sorted(),
                            "roots": grant.canonicalRoots.sorted(),
                            "expires_at": ISO8601DateFormatter().string(from: grant.expiresAt),
                            "revoked": grant.revokedAt != nil,
                            "revision": grant.revision
                        ] as [String: Any]
                    }
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                return 0
            case "grant":
                let options = try parseOptions(Array(arguments.dropFirst()))
                guard let principalFingerprint = options.single["principal-fingerprint"] ?? options.single["principal"],
                      !principalFingerprint.isEmpty
                else {
                    throw CommandError.invalidArguments(
                        "policy grant requires --principal-fingerprint <verified-identity-fingerprint>"
                    )
                }
                let operations = Set(options.multiple["operation"] ?? [])
                guard !operations.isEmpty else {
                    throw CommandError.invalidArguments("policy grant requires one or more --operation <tool.action>")
                }
                let expirySeconds = try positiveSeconds(options.single["expires-in"] ?? "3600")
                let roots = Set((options.multiple["root"] ?? []).map(canonicalRoot))
                let (snapshot, _) = await store.snapshot()
                let grant = DomainHeadlessMutationGrant(
                    principalKey: principalFingerprint,
                    allowedOperations: operations,
                    canonicalRoots: roots,
                    provider: options.single["provider"],
                    expiresAt: Date().addingTimeInterval(expirySeconds)
                )
                try confirm("Grant \(principalFingerprint) operations=[\(operations.sorted().joined(separator: ","))] roots=[\(roots.sorted().joined(separator: ","))] until \(grant.expiresAt)?")
                let updated = try await store.addGrant(
                    grant,
                    expectedRevision: snapshot.revision,
                    administrator: administrator
                )
                print("Grant \(grant.id.uuidString) stored at policy revision \(updated.revision).")
                return 0
            case "revoke":
                let options = try parseOptions(Array(arguments.dropFirst()))
                guard let rawID = options.single["id"], let id = UUID(uuidString: rawID) else {
                    throw CommandError.invalidArguments("policy revoke requires --id <uuid>")
                }
                let (snapshot, _) = await store.snapshot()
                try confirm("Revoke grant \(id.uuidString)?")
                let updated = try await store.revokeGrant(
                    id: id,
                    expectedRevision: snapshot.revision,
                    administrator: administrator
                )
                print("Grant \(id.uuidString) revoked at policy revision \(updated.revision).")
                return 0
            default:
                throw CommandError.invalidArguments(usage)
            }
        } catch {
            fputs("RepoPrompt MCP policy: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    private struct ParsedOptions {
        var single: [String: String] = [:]
        var multiple: [String: [String]] = [:]
    }

    private static func parseOptions(_ arguments: [String]) throws -> ParsedOptions {
        var result = ParsedOptions()
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw CommandError.invalidArguments("Expected --key value option, got '\(key)'.")
            }
            let name = String(key.dropFirst(2))
            let value = arguments[index + 1]
            result.single[name] = value
            result.multiple[name, default: []].append(value)
            index += 2
        }
        return result
    }

    private static func positiveSeconds(_ raw: String) throws -> TimeInterval {
        guard let value = TimeInterval(raw), value.isFinite, value > 0 else {
            throw CommandError.invalidArguments("--expires-in must be a positive number of seconds")
        }
        return value
    }

    private static func canonicalRoot(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func confirm(_ prompt: String) throws {
        fputs("\(prompt) Type 'yes' to continue: ", stderr)
        guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" else {
            throw CommandError.confirmationDeclined
        }
    }

    private static func makeRuntime() -> MCPDomainRuntime {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = applicationSupport.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        return MCPDomainRuntime(configuration: DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "default",
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt CE", isDirectory: true),
            externalReloadInterval: nil
        ))
    }

    private static let usage = """
    Usage:
      rpce-cli policy list
      rpce-cli policy grant --principal-fingerprint <verified-identity-fingerprint> --operation <tool.action> [--operation ...] [--root <path>] [--provider <name>] [--expires-in <seconds>]
      rpce-cli policy revoke --id <uuid>
    Policy administration requires interactive stdin and stderr TTYs; mutation commands require immediate confirmation.
    """
}
