import SwiftUI

extension EnvironmentValues {
    /// Whether the hosting window is currently presented on screen: visible, not miniaturized, not
    /// fully occluded (including another Space), and its app not hidden.
    ///
    /// Presentation-only. It exists so purely decorative, continuously running animations can stop
    /// while nobody can see them; it must never gate execution, persistence, or model publication.
    /// Defaults to `true` so a view outside a tracked window keeps its existing behavior.
    @Entry var windowIsPresentationVisible: Bool = true
}
