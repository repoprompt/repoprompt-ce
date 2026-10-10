import AppKit
import SwiftUI

/// Role colours, independent of link-group allocation and the app's selection accent.
enum AgentOversightRoleStyle {
    static let overseerNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 179 / 255, blue: 64 / 255, alpha: 1)
            : NSColor(srgbRed: 194 / 255, green: 106 / 255, blue: 0, alpha: 1)
    }

    static var overseer: Color {
        Color(nsColor: overseerNSColor)
    }

    static var worker: Color {
        Color(nsColor: .systemGray)
    }
}

/// Foreground-style-respecting vectors on a centred 24-point grid.
/// Callers own the role colour and accessibility copy; the faded parent distinguishes a worker.
struct AgentOversightRoleIcon: View {
    enum Role: Hashable {
        case overseer
        case worker

        static func toolbarRoles(isOverseer: Bool, hasInbound: Bool) -> [Self] {
            if isOverseer {
                return hasInbound ? [.overseer, .worker] : [.overseer]
            }
            return hasInbound ? [.worker] : [.overseer]
        }
    }

    let role: Role
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, bounds in
            let scale = min(bounds.width, bounds.height) / 24
            context.translateBy(x: (bounds.width - 24 * scale) / 2, y: (bounds.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            var links = Path()
            var satellites = Path()
            let centre: CGRect
            switch role {
            case .overseer:
                links.move(to: CGPoint(x: 12, y: 9))
                links.addLine(to: CGPoint(x: 12, y: 5.5))
                links.move(to: CGPoint(x: 9.5, y: 13.6))
                links.addLine(to: CGPoint(x: 6.2, y: 16.8))
                links.move(to: CGPoint(x: 14.5, y: 13.6))
                links.addLine(to: CGPoint(x: 17.8, y: 16.8))
                satellites.addEllipse(in: CGRect(x: 10, y: 1.5, width: 4, height: 4))
                satellites.addEllipse(in: CGRect(x: 2.5, y: 16, width: 4, height: 4))
                satellites.addEllipse(in: CGRect(x: 17.5, y: 16, width: 4, height: 4))
                centre = CGRect(x: 9, y: 9, width: 6, height: 6)
            case .worker:
                links.move(to: CGPoint(x: 12, y: 7))
                links.addLine(to: CGPoint(x: 12, y: 12.8))
                satellites.addEllipse(in: CGRect(x: 9.7, y: 2.2, width: 4.6, height: 4.6))
                centre = CGRect(x: 8, y: 13, width: 8, height: 8)
            }
            var parentContext = context
            parentContext.opacity = role == .worker ? 0.5 : 1
            // Fade the parent as one layer so the ring/link overlap does not darken.
            parentContext.drawLayer { layer in
                layer.stroke(links, with: .foreground, style: stroke)
                layer.stroke(satellites, with: .foreground, style: stroke)
            }
            context.fill(Path(ellipseIn: centre), with: .foreground)
        }
        .frame(width: size, height: size)
    }
}
