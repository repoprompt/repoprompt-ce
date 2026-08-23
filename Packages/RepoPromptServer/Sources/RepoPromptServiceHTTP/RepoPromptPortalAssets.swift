import Foundation
import Hummingbird
import RepoPromptServiceProtocol

public enum RepoPromptPortalAssets {
    public enum Asset: String, CaseIterable, Sendable {
        case index = "index.html"
        case stylesheet = "portal.css"
        case script = "portal.js"
        case appIcon = "repoprompt-icon.png"

        public init?(routeName: String) {
            self.init(rawValue: routeName)
        }

        fileprivate var contentType: String {
            switch self {
            case .index: "text/html; charset=utf-8"
            case .stylesheet: "text/css; charset=utf-8"
            case .script: "text/javascript; charset=utf-8"
            case .appIcon: "image/png"
            }
        }
    }

    public static func data(for asset: Asset) throws -> Data {
        let parts = asset.rawValue.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let url = Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Portal")
                ?? Bundle.module.url(forResource: parts[0], withExtension: parts[1])
        else {
            throw ServiceAPIError(code: .notFound, message: "Portal asset is not bundled")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    public static func response(for asset: Asset) throws -> Response {
        let body = try data(for: asset)
        var headers = securityHeaders(contentType: asset.contentType)
        headers[.cacheControl] = asset == .index ? "private, no-store" : "private, max-age=3600"
        if asset == .index {
            headers[.init("Content-Security-Policy")!] = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        }
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: body)))
    }

    public static func canonicalRedirect() -> Response {
        var headers = securityHeaders(contentType: "text/plain; charset=utf-8")
        headers[.location] = "/portal/"
        headers[.cacheControl] = "private, no-store"
        return Response(status: HTTPResponse.Status(code: 308), headers: headers)
    }

    public static func securityHeaders(contentType: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.contentType] = contentType
        headers[.init("X-Content-Type-Options")!] = "nosniff"
        headers[.init("Referrer-Policy")!] = "no-referrer"
        headers[.init("X-Frame-Options")!] = "DENY"
        headers[.init("Cross-Origin-Opener-Policy")!] = "same-origin"
        return headers
    }
}

public enum RepoPromptPortalRequestProtection {
    public static func validateMutation(
        origin: String?,
        expectedOrigin: String,
        fetchSite: String?,
        contentType: String?,
        csrfHeader: String?
    ) throws {
        guard !expectedOrigin.isEmpty,
              origin?.lowercased() == expectedOrigin.lowercased()
        else {
            throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Portal mutation origin is not allowed")
        }
        if let fetchSite, fetchSite.lowercased() != "same-origin" {
            throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Cross-site portal mutation is not allowed")
        }
        guard contentType?.lowercased().split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "application/json",
              csrfHeader == "1"
        else {
            throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Portal mutation headers are invalid")
        }
    }
}

public enum RepoPromptPortalCertificateAuthorization {
    public static func allows(_ role: InternalRouteRole) -> Bool {
        role == .operatorRole || role == .app
    }
}
