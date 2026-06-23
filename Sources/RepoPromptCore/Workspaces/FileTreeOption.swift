import Foundation

package enum FileTreeOption: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case files = "Full"
    case selected = "Selected"
    case none = "None"

    package var id: String {
        rawValue
    }
}
