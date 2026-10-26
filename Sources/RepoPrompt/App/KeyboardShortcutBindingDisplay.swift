import AppKit
import Combine
import KeyboardShortcuts

/// Display only: assignments and dispatch remain owned by KeyboardShortcuts.
/// Managed menu items deliberately have no native key equivalent. A second menu binding
/// would reserve the old keys and make the library's recorder reject remapping on macOS 15.
@MainActor
final class KeyboardShortcutBindingDisplay: ObservableObject {
    @Published private(set) var labels: [KeyboardShortcuts.Name: String] = [:]
    private var observations: Set<AnyCancellable> = []

    init() {
        refresh()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
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
    }

    func title(_ title: String, for name: KeyboardShortcuts.Name) -> String {
        guard let label = labels[name], !label.isEmpty else { return title }
        return "\(title)    \(label)"
    }
}
