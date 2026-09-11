import Foundation

/// Advisory presentation metadata from Devin's account catalog. It never adds a
/// selectable model: the controller annotates only IDs its ACP session advertises.
final class DevinModelFamilyCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var familiesByModel: [String: AgentModelFamily] = [:]

    func family(for rawModel: String) -> AgentModelFamily? {
        lock.withLock { familiesByModel[rawModel] }
    }

    func refresh(launch: DevinACPResolvedLaunch) async throws {
        lock.withLock { familiesByModel = [:] }
        do {
            try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
            let runner = CLIProcessRunner(config: CLIProcessConfiguration(
                command: launch.command,
                environment: launch.environment,
                additionalPaths: [],
                enableDebugLogging: false,
                shellLookupMode: .fallbackOnly
            ))
            let result = try await runner.run(
                args: ["models", "list", "--format", "json"], stdin: nil,
                outputMode: .none, timeout: 10, cancelChildOnTaskCancellation: true
            )
            try Task.checkCancellation()
            guard result.status == 0 else { return }
            let parsed = try Self.parse(result.stdout)
            lock.withLock { familiesByModel = parsed }
        } catch {
            // Older CLI versions or unavailable catalog metadata leave an ordinary
            // flat picker. Never block a valid ACP session or infer family from an ID.
            try Task.checkCancellation()
        }
    }

    static func parse(_ data: Data) throws -> [String: AgentModelFamily] {
        struct Catalog: Decodable {
            struct Family: Decodable {
                struct Variant: Decodable {
                    let modelID: String
                    enum CodingKeys: String, CodingKey { case modelID = "model_uid" }
                }

                let familyID: String
                let familyLabel: String
                let variants: [Variant]
                enum CodingKeys: String, CodingKey {
                    case familyID = "family_uid"
                    case familyLabel = "family_label"
                    case variants
                }
            }

            let families: [Family]
        }
        enum InvalidCatalog: Error { case invalidOrDuplicateIdentity }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var result: [String: AgentModelFamily] = [:]
        var familyIDs = Set<String>()
        for family in catalog.families {
            guard !family.familyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !family.familyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  familyIDs.insert(family.familyID).inserted else { throw InvalidCatalog.invalidOrDuplicateIdentity }
            for variant in family.variants {
                guard !variant.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      result[variant.modelID] == nil else { throw InvalidCatalog.invalidOrDuplicateIdentity }
                result[variant.modelID] = AgentModelFamily(id: family.familyID, displayName: family.familyLabel)
            }
        }
        return result
    }
}
