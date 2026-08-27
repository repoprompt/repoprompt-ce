import Foundation

// SEARCH-HELPER: OpenAI Base URL, Custom Base URL, URL Normalization
enum OpenAIURLHelper {
    /// Splits a raw base URL into a normalized base (without trailing version) and an optional version string (e.g., "v1", "v4").
    /// - Important: Adds https:// if missing, removes trailing slashes, and detects only the **last** path segment if it matches ^v\\d+([A-Za-z0-9._-]+)?$.
    static func splitBaseURLAndVersion(_ raw: String?) -> (base: URL?, version: String?) {
        guard var s = raw, !s.isEmpty else { return (nil, nil) }

        // Add protocol if missing
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        // Trim trailing slashes for stable parsing
        while s.hasSuffix("/") {
            s.removeLast()
        }

        guard let url = URL(string: s),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return (URL(string: s), nil)
        }

        var path = comps.path
        while path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }

        var detectedVersion: String? = nil
        if let last = path.split(separator: "/").last {
            let lastStr = String(last)
            // Match v{digits} optionally followed by alnum/._- (e.g., v1, v4, v1-beta)
            if lastStr.range(of: #"^v\d+([A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil {
                detectedVersion = lastStr
                if let r = path.range(of: "/\(lastStr)", options: .backwards) {
                    path.removeSubrange(r)
                }
            }
        }

        if path.hasSuffix("/"), path != "/" { path.removeLast() }
        comps.path = path
        // Rebuild a string without the trailing /vN if any
        let baseStr = comps.string ?? s
        return (URL(string: baseStr), detectedVersion)
    }

    /// Returns whether an endpoint should be treated as OpenAI-owned.
    ///
    /// A nil base URL represents SwiftOpenAI's native/default OpenAI endpoint. The host rule
    /// intentionally matches only api.openai.com and subdomains of openai.com, not the apex or
    /// lookalike suffixes.
    static func isOpenAIOwnedEndpoint(_ baseURL: URL?) -> Bool {
        guard let baseURL else { return true }
        guard let host = baseURL.host?.lowercased(), !host.isEmpty else { return false }
        return host == "api.openai.com" || host.hasSuffix(".openai.com")
    }

    /// Normalizes a custom OpenAI base URL by:
    /// 1. Adding https:// if no protocol specified
    /// 2. Removing a trailing /vN suffix (OpenAI-compatible endpoints)
    /// 3. Removing trailing slashes for consistency
    static func normalizeBaseURL(_ raw: String?) -> URL? {
        splitBaseURLAndVersion(raw).base
    }

    /// String version of the normalization for cases where String is needed
    static func normalizeBaseURLString(_ raw: String?) -> String? {
        guard let url = normalizeBaseURL(raw) else { return nil }
        return url.absoluteString
    }
}
