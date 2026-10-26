import AppKit
import Combine
import KeyboardShortcuts
import RepoPromptSettingsCore

/// Display only: assignments and dispatch remain owned by KeyboardShortcuts.
/// Managed menu items deliberately have no native key equivalent. A second menu binding
/// would reserve the old keys and make the library's recorder reject remapping on macOS 15.
@MainActor
final class KeyboardShortcutBindingDisplay: ObservableObject {
    @Published private(set) var labels: [KeyboardShortcuts.Name: String] = [:]
    /// Mirrors the master switch so in-content hints for local bindings disappear when it is off.
    @Published private(set) var shortcutsEnabled = true
    private var observations: Set<AnyCancellable> = []

    init() {
        refresh()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .map { _ in () }
            .merge(with: GlobalSettingsStore.shared.objectWillChange.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)
    }

    func refresh() {
        let names = KeyboardShortcutCatalog.sections.flatMap(\.bindings).map(\.name)
        let updated = Dictionary(uniqueKeysWithValues: names.map { name in
            (name, KeyboardShortcuts.getShortcut(for: name)?.description ?? "")
        })
        if labels != updated { labels = updated }
        let enabled = GlobalSettingsStore.shared.enableKeyboardShortcuts()
        if shortcutsEnabled != enabled { shortcutsEnabled = enabled }
    }

    /// Hint text for a view-dispatched binding: empty when cleared or when shortcuts are off.
    func localLabel(for name: KeyboardShortcuts.Name) -> String {
        shortcutsEnabled ? labels[name] ?? "" : ""
    }

    func title(_ title: String, for name: KeyboardShortcuts.Name) -> String {
        guard let label = labels[name], !label.isEmpty else { return title }
        return "\(title)    \(label)"
    }
}
