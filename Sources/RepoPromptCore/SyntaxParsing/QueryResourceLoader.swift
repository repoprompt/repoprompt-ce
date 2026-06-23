import Foundation

/// Loads query `.scm` files that were copied into the binary as
/// Swift-PM resources (e.g. via `.copy("queries")` in `Package.swift`).
/// We currently only need PHP support, but the helper can be reused.
package enum QueryResourceLoader {
    /// Returns the *raw Data* for *queries/highlights.scm* bundled with
    /// the `TreeSitterPHP` Swift-PM package, or `nil` if the file cannot
    /// be found.
    static func phpHighlightData() -> Data? {
        let bundleNameKey = "treesitterphp"
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            let bundleName = bundle.bundleURL.lastPathComponent.lowercased()
            if bundleName.contains(bundleNameKey),
               let url = bundle.url(
                   forResource: "highlights",
                   withExtension: "scm",
                   subdirectory: "queries"
               )
            {
                return try? Data(contentsOf: url)
            }
        }
        return nil
    }

    /// Convenience wrapper that converts the raw data into `String`
    /// when a textual representation is preferred by the caller.
    static func phpHighlight() -> String? {
        guard let data = phpHighlightData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
