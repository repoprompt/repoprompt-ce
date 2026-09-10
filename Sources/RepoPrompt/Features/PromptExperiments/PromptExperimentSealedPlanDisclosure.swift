#if DEBUG
    import Foundation
    import SwiftUI

    enum PromptExperimentSealedPlanPresentation {
        static func prettyPrintedJSON(_ plan: PromptExperimentPlan) throws -> String {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try String(decoding: encoder.encode(plan), as: UTF8.self)
        }

        static func displayJSON(_ plan: PromptExperimentPlan) -> String {
            do {
                return try prettyPrintedJSON(plan)
            } catch {
                return "Sealed plan JSON is unavailable: \(error.localizedDescription)"
            }
        }
    }

    /// Shared complete authority disclosure used wherever a native user can approve a plan.
    struct PromptExperimentSealedPlanDisclosure: View {
        let plan: PromptExperimentPlan

        var body: some View {
            DisclosureGroup("Inspect complete sealed plan JSON") {
                ScrollView([.horizontal, .vertical]) {
                    Text(PromptExperimentSealedPlanPresentation.displayJSON(plan))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .frame(maxHeight: 320)
            }
        }
    }
#endif
