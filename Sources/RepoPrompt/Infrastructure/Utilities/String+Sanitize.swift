import Foundation

extension String {
    /// Returns a copy of this string safe for bridging to NSString and rendering in SwiftUI Text views.
    ///
    /// AI-generated content can contain characters (e.g. null bytes) that are technically valid in Swift's
    /// String type but trigger `_assertionFailure` in Swift/StringBridge.swift when CoreText bridges the
    /// value to NSString during layout. This strips those characters to prevent fatal crashes.
    var sanitizedForDisplay: String {
        // Remove null bytes (\0), which are legal in Swift String / NSString but break
        // the NSString <-> Swift String bridge in certain CoreText/SwiftUI rendering paths.
        filter { $0 != "\0" }
    }
}
