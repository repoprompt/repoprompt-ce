import Foundation
import Hummingbird
import RepoPromptServiceProtocol

public enum HTTPResponses {
    public static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder.serviceEncoder.encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(data)
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    public static func privateJSON(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        var response = try json(value, status: status)
        response.headers[.cacheControl] = "private, no-store"
        response.headers[.vary] = "Cookie, Authorization"
        return response
    }

    public static func empty(status: HTTPResponse.Status = .noContent) -> Response {
        var headers = HTTPFields()
        headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(Data())
        return Response(status: status, headers: headers)
    }

    public static func privateEmpty(status: HTTPResponse.Status = .noContent) -> Response {
        var response = empty(status: status)
        response.headers[.cacheControl] = "private, no-store"
        response.headers[.vary] = "Cookie, Authorization"
        return response
    }

    public static func bytes(_ data: Data, status: HTTPResponse.Status = .ok, contentType: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = contentType
        headers[.cacheControl] = "no-store"
        headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(data)
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    public static func privateBytes(_ data: Data, status: HTTPResponse.Status = .ok, contentType: String) -> Response {
        var response = bytes(data, status: status, contentType: contentType)
        response.headers[.cacheControl] = "private, no-store"
        response.headers[.vary] = "Cookie, Authorization"
        return response
    }

    public static func error(_ error: Error) -> Response {
        let apiError = error as? ServiceAPIError ?? ServiceAPIError(code: .internalFailure, message: "Internal service failure", retryable: false)
        if apiError.code == .cursorExpired, let cursor = apiError.cursor {
            return (try? json(CursorExpiredResponse(storeID: cursor.storeID, replayFloor: cursor.globalSequence), status: .gone)) ?? Response(status: .internalServerError)
        }
        let status: HTTPResponse.Status = switch apiError.code {
        case .invalidRequest: .badRequest
        case .internalAuthFailed: .unauthorized
        case .authorizationDecisionRejected, .resourceOwnerMismatch, .resourceContextMismatch: .forbidden
        case .notFound: .notFound
        case .staleRevision, .controllerChanged, .interactionSettled, .idempotencyConflict, .runAlreadyActive: .conflict
        case .cursorExpired, .resourceDeleted, .expiredResource: .gone
        case .rateLimited: .tooManyRequests
        case .dependencyUnavailable, .quiescing, .persistenceUnavailable: .serviceUnavailable
        case .internalFailure: .internalServerError
        default: .unprocessableContent
        }
        return (try? json(apiError, status: status)) ?? Response(status: .internalServerError)
    }
}
