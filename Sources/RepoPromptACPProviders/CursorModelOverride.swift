import Foundation

package struct CursorModelOverride {
    package let configID: String
    package let valueRaw: String

    package init(configID: String, valueRaw: String) {
        self.configID = configID
        self.valueRaw = valueRaw
    }
}
