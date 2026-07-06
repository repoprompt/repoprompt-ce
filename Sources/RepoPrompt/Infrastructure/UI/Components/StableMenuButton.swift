import AppKit
import SwiftUI

/// A SwiftUI-labelled button that presents an AppKit `NSMenu`.
///
/// Use this instead of SwiftUI `Menu` for long-lived model pickers that sit in highly
/// reactive views. AppKit owns menu tracking, so unrelated SwiftUI invalidations do
/// not tear down the open picker.
struct StableMenuButton<Label: View>: View {
    enum TriggerStyle {
        case automatic
        case borderless
        case plain
    }

    let items: () -> [StableMenuItem]
    let triggerStyle: TriggerStyle
    let openRequestCount: Int
    let onOpen: @MainActor () -> Void
    @ViewBuilder let label: () -> Label

    @StateObject private var presenter = StableMenuPresenter()

    init(
        items: @escaping () -> [StableMenuItem],
        triggerStyle: TriggerStyle = .automatic,
        openRequestCount: Int = 0,
        onOpen: @escaping @MainActor () -> Void = {},
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.items = items
        self.triggerStyle = triggerStyle
        self.openRequestCount = openRequestCount
        self.onOpen = onOpen
        self.label = label
    }

    var body: some View {
        switch triggerStyle {
        case .automatic:
            button
        case .borderless:
            button.buttonStyle(.borderless)
        case .plain:
            button.buttonStyle(.plain)
        }
    }

    private var button: some View {
        Button {
            presentMenu()
        } label: {
            label()
        }
        .background(
            StableMenuAnchorView(presenter: presenter)
                .allowsHitTesting(false)
        )
        .onChange(of: openRequestCount) {
            DispatchQueue.main.async {
                presentMenu()
            }
        }
    }

    private func presentMenu() {
        onOpen()
        presenter.present(items())
    }
}

enum StableMenuItemStyle: Equatable {
    case normal
    case warning
}

struct StableMenuItem {
    private enum Kind {
        case action(() -> Void)
        case submenu([StableMenuItem])
        case separator
        case header
    }

    private let kind: Kind
    let title: String
    let isEnabled: Bool
    let isSelected: Bool
    let imageSystemName: String?
    let style: StableMenuItemStyle

    private init(
        title: String,
        kind: Kind,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        imageSystemName: String? = nil,
        style: StableMenuItemStyle = .normal
    ) {
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.imageSystemName = imageSystemName
        self.style = style
    }

    static func action(
        _ title: String,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        imageSystemName: String? = nil,
        style: StableMenuItemStyle = .normal,
        _ action: @escaping () -> Void
    ) -> StableMenuItem {
        StableMenuItem(
            title: title,
            kind: .action(action),
            isEnabled: isEnabled,
            isSelected: isSelected,
            imageSystemName: imageSystemName,
            style: style
        )
    }

    static func submenu(
        _ title: String,
        imageSystemName: String? = nil,
        style: StableMenuItemStyle = .normal,
        items: [StableMenuItem]
    ) -> StableMenuItem {
        StableMenuItem(title: title, kind: .submenu(items), imageSystemName: imageSystemName, style: style)
    }

    static func header(_ title: String) -> StableMenuItem {
        StableMenuItem(title: title, kind: .header, isEnabled: false)
    }

    static func message(_ title: String) -> StableMenuItem {
        StableMenuItem(title: title, kind: .header, isEnabled: false)
    }

    static var separator: StableMenuItem {
        StableMenuItem(title: "", kind: .separator, isEnabled: false)
    }

    fileprivate func makeMenuItem(fontPreset: FontScalePreset = .current) -> NSMenuItem {
        switch kind {
        case .separator:
            return .separator()
        case .header:
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            configureImage(on: item)
            configureTitle(on: item, fontPreset: fontPreset)
            return item
        case let .action(action):
            let item = NSMenuItem(title: title, action: #selector(StableMenuActionBox.invoke), keyEquivalent: "")
            let actionBox = StableMenuActionBox(action: action)
            item.target = actionBox
            item.representedObject = actionBox
            item.isEnabled = isEnabled
            item.state = isSelected ? .on : .off
            configureImage(on: item)
            configureTitle(on: item, fontPreset: fontPreset)
            return item
        case let .submenu(childItems):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = isEnabled
            item.state = isSelected ? .on : .off
            item.submenu = NSMenu.stableMenu(from: childItems, fontPreset: fontPreset)
            configureImage(on: item)
            configureTitle(on: item, fontPreset: fontPreset)
            return item
        }
    }

    private func configureImage(on item: NSMenuItem) {
        guard let imageSystemName,
              let image = NSImage(systemSymbolName: imageSystemName, accessibilityDescription: title)
        else {
            return
        }
        if style == .warning,
           let warningImage = image.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        {
            warningImage.isTemplate = false
            item.image = warningImage
        } else {
            image.isTemplate = true
            item.image = image
        }
    }

    private func configureTitle(on item: NSMenuItem, fontPreset: FontScalePreset) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fontPreset.nsFont(sizeAtNormal: CGFloat(NSFont.systemFontSize), rounded: false)
        ]
        if style == .warning {
            attributes[.foregroundColor] = NSColor.systemOrange
        }
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}

private extension NSMenu {
    static func stableMenu(from items: [StableMenuItem], fontPreset: FontScalePreset = .current) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            menu.addItem(item.makeMenuItem(fontPreset: fontPreset))
        }
        return menu
    }
}

@MainActor
private final class StableMenuPresenter: NSObject, ObservableObject, NSMenuDelegate {
    weak var anchorView: NSView?
    private var retainedMenu: NSMenu?

    func present(_ items: [StableMenuItem]) {
        guard !items.isEmpty else { return }
        guard let anchorView, anchorView.window != nil else { return }

        retainedMenu?.cancelTracking()
        let menu = NSMenu.stableMenu(from: items, fontPreset: FontScalePreset.current)
        menu.delegate = self
        retainedMenu = menu

        let popupPoint = NSPoint(x: 0, y: anchorView.bounds.height + 2)
        menu.popUp(positioning: nil, at: popupPoint, in: anchorView)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard retainedMenu === menu else { return }
        retainedMenu = nil
    }
}

private final class StableMenuActionBox: NSObject {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

@MainActor
private struct StableMenuAnchorView: NSViewRepresentable {
    @ObservedObject var presenter: StableMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        presenter.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchorView = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Do not cancel tracking here. SwiftUI may rebuild the trigger while the AppKit
        // menu is open; retaining the menu through `StableMenuPresenter` is the point.
    }
}
