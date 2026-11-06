#if DEBUG
    import AppKit
    import SwiftUI

    /// Inert leaf instrumentation for AgentTranscriptTailInvalidationDiagnostics (opt-in XCTest).
    /// The recorder and native identity map belong to the test, never to SwiftUI state.
    @MainActor
    enum AgentTranscriptTailRenderProbe {
        enum NativeBoundary: String {
            case make, update, replacement, size, ensureLayout, draw
        }

        enum Event {
            case block(String)
            case body(UUID, String)
            case footer(UUID?, String)
            case native(NativeBoundary, UUID?, CodeBlockTextView)
        }

        static var sink: ((Event) -> Void)?
    }

    extension EnvironmentValues {
        @Entry var agentTranscriptProbeRowID: UUID?
    }
#endif
