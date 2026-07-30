import AppKit
import SwiftUI

/// The semantic direction role of a text surface.
enum TextDirectionRole: CaseIterable, Equatable {
    /// Prose whose paragraph direction should remain platform-resolved.
    /// Applying this role is intentionally a no-op and does not reset an existing override.
    case naturalProse

    /// Dedicated source-code or diff content that should use an LTR base direction.
    case dedicatedLeftToRight

    /// A code block embedded within otherwise natural-direction Markdown.
    case markdownCodeBlock
}

/// The shared authority for mapping semantic text roles to framework direction settings.
enum TextDirectionPolicy {
    enum BaseDirection: Equatable {
        case natural
        case leftToRight
    }

    /// Returns `.natural` for the no-op natural-prose role and LTR for explicit roles.
    static func baseDirection(for role: TextDirectionRole) -> BaseDirection {
        switch role {
        case .naturalProse:
            .natural
        case .dedicatedLeftToRight, .markdownCodeBlock:
            .leftToRight
        }
    }

    static func appKitBaseWritingDirection(for role: TextDirectionRole) -> NSWritingDirection? {
        switch baseDirection(for: role) {
        case .natural:
            nil
        case .leftToRight:
            .leftToRight
        }
    }

    /// Maps roles to SwiftUI layout direction.
    ///
    /// The Markdown code-block mapping is provisional until its SwiftUI integration is designed;
    /// unlike AppKit paragraph direction, this environment value affects an entire descendant layout.
    static func swiftUILayoutDirection(for role: TextDirectionRole) -> LayoutDirection? {
        switch baseDirection(for: role) {
        case .natural:
            nil
        case .leftToRight:
            .leftToRight
        }
    }

    /// Applies only the role's explicit base direction, leaving natural-direction styles unchanged.
    static func apply(_ role: TextDirectionRole, to paragraphStyle: NSMutableParagraphStyle) {
        guard let direction = appKitBaseWritingDirection(for: role) else { return }
        paragraphStyle.baseWritingDirection = direction
    }

    /// Applies only the role's explicit base direction and never changes the text view's string.
    ///
    /// `NSTextView.baseWritingDirection` does not override explicit paragraph styles already stored
    /// in attributed content. Future diff integration must also use the paragraph-style adapter.
    @MainActor
    static func apply(_ role: TextDirectionRole, to textView: NSTextView) {
        guard let direction = appKitBaseWritingDirection(for: role) else { return }
        textView.baseWritingDirection = direction
    }
}

extension View {
    /// Applies an explicit SwiftUI layout direction only when the semantic role requires one.
    ///
    /// SwiftUI's `layoutDirection` flips the entire descendant layout, not only text resolution.
    /// Apply this modifier only to a narrow leaf or dedicated text subtree, never a mixed container.
    /// The Markdown code-block role remains provisional for SwiftUI until such a scope is established.
    @ViewBuilder
    func semanticTextDirection(_ role: TextDirectionRole) -> some View {
        if let direction = TextDirectionPolicy.swiftUILayoutDirection(for: role) {
            environment(\.layoutDirection, direction)
        } else {
            self
        }
    }
}
