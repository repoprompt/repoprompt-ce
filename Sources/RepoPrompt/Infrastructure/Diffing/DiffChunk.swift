import RepoPromptDomainRuntime
import SwiftUI

package extension DiffLine {
    var prefixColor: Color {
        switch type {
        case .addition: .green
        case .removal: .red
        case .context: .primary
        }
    }

    var contentColor: Color {
        switch type {
        case .addition, .removal: .primary
        case .context: .secondary
        }
    }

    var backgroundColor: Color {
        switch type {
        case .addition: Color.green.opacity(0.1)
        case .removal: Color.red.opacity(0.1)
        case .context: Color.clear
        }
    }
}
