import Foundation

package enum CLIOutputFormat: String {
    case text
    case json
    case streamJson = "stream-json"

    package var tokens: [String] {
        ["--output-format", rawValue]
    }
}
