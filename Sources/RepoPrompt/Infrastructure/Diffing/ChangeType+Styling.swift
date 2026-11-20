import RepoPromptDomainRuntime
import SwiftUI

extension ChangeType {
    var color: Color {
        switch self {
        case .add: .green
        case .modify: .yellow
        case .remove: .red
        }
    }

    func printDetails() {
        print("Change Type:")
        print("  Raw Value: \(rawValue)")
        print("  Display String: \(displayString)")
        print("  Color: \(color)")
        print("")
    }
}
