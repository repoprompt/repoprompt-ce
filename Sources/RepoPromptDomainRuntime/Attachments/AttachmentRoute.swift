import Foundation

/// An encoder route, keyed by the code that builds the wire payload and not by the provider company.
package enum AttachmentRoute: String, CaseIterable {
    case anthropicMessages
    case openAIResponses
    case openAIChat
    case customOpenAI
    case claudeCodeStreamJSON
    case codexAppServer
    case acp
    case grokBuild
}

package enum ImageRung: Equatable { case nativeImage, unsupported }
package enum DocumentRung: Equatable { case nativeDocument, unsupported }
package enum TextRung: Equatable { case inlineText, unsupported }
package enum BinaryRung: Equatable { case unsupported }

/// The initializer has no default values on purpose. Adding a field for a new kind breaks the
/// initializer call of every row until each route answers it.
package struct AttachmentRouteCapability: Equatable {
    package let displayName: String
    package let image: ImageRung
    package let pdf: DocumentRung
    package let text: TextRung
    package let binary: BinaryRung
    /// Largest encoded request the route's SDK accepts, or nil when the route enforces none.
    package let maxEncodedRequestBytes: Int?

    package init(
        displayName: String,
        image: ImageRung,
        pdf: DocumentRung,
        text: TextRung,
        binary: BinaryRung,
        maxEncodedRequestBytes: Int?
    ) {
        self.displayName = displayName
        self.image = image
        self.pdf = pdf
        self.text = text
        self.binary = binary
        self.maxEncodedRequestBytes = maxEncodedRequestBytes
    }

    /// Every cell is grounded in encoder code. Widen one only after a live smoke proves delivery.
    /// Binary stays refused everywhere: the Claude Code, Codex, ACP and Grok Build Oracle one-shots
    /// run without file tools, so a path mention would admit a file the model can never open.
    /// Claude stream-json documents and ACP embedded resources are unproven.
    package static func capability(for route: AttachmentRoute) -> AttachmentRouteCapability {
        switch route {
        case .anthropicMessages:
            AttachmentRouteCapability(
                displayName: "Anthropic Messages",
                image: .nativeImage,
                pdf: .nativeDocument,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: 32_000_000
            )
        case .openAIResponses:
            AttachmentRouteCapability(
                displayName: "OpenAI Responses",
                image: .nativeImage,
                pdf: .nativeDocument,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: nil
            )
        case .openAIChat:
            AttachmentRouteCapability(
                displayName: "OpenAI Chat Completions",
                image: .nativeImage,
                pdf: .unsupported,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: nil
            )
        case .customOpenAI:
            AttachmentRouteCapability(
                displayName: "Custom OpenAI-compatible",
                image: .nativeImage,
                pdf: .unsupported,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: nil
            )
        case .claudeCodeStreamJSON:
            AttachmentRouteCapability(
                displayName: "Claude Code",
                image: .nativeImage,
                pdf: .unsupported,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: nil
            )
        case .codexAppServer:
            AttachmentRouteCapability(
                displayName: "Codex",
                image: .nativeImage,
                pdf: .unsupported,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: nil
            )
        case .acp:
            AttachmentRouteCapability(
                displayName: "ACP agent",
                image: .nativeImage,
                pdf: .unsupported,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: nil
            )
        case .grokBuild:
            AttachmentRouteCapability(
                displayName: "Grok Build",
                image: .unsupported,
                pdf: .unsupported,
                text: .inlineText,
                binary: .unsupported,
                maxEncodedRequestBytes: nil
            )
        }
    }
}
