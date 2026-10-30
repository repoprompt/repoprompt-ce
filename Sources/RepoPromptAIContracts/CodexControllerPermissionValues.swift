import Foundation

package enum CodexAppServerRequestValueStyle: CaseIterable {
    case configStyle
    case camelCase
}

package enum CodexApprovalPolicy: CaseIterable {
    case onRequest
    case unlessTrusted
    case never

    package var displayName: String {
        switch self {
        case .onRequest:
            "On Request"
        case .unlessTrusted:
            "Unless Trusted"
        case .never:
            "Never"
        }
    }

    package var persistedValue: String {
        switch self {
        case .onRequest:
            "on-request"
        case .unlessTrusted:
            "unless-trusted"
        case .never:
            "never"
        }
    }

    package func appServerRequestValue(style: CodexAppServerRequestValueStyle) -> String {
        switch style {
        case .configStyle:
            switch self {
            case .onRequest:
                "on-request"
            case .unlessTrusted:
                "untrusted"
            case .never:
                "never"
            }
        case .camelCase:
            switch self {
            case .onRequest:
                "onRequest"
            case .unlessTrusted:
                "unlessTrusted"
            case .never:
                "never"
            }
        }
    }

    package init?(storedValue: String) {
        switch storedValue {
        case "onRequest", "on-request":
            self = .onRequest
        case "onFailure", "on-failure":
            self = .onRequest
        case "unlessTrusted", "unless-trusted", "untrusted":
            self = .unlessTrusted
        case "never":
            self = .never
        default:
            return nil
        }
    }
}

package enum CodexSandboxMode: CaseIterable {
    case readOnly
    case workspaceWrite
    case dangerFullAccess

    package var displayName: String {
        switch self {
        case .readOnly:
            "Read Only"
        case .workspaceWrite:
            "Workspace Write"
        case .dangerFullAccess:
            "Danger Full Access"
        }
    }

    package var persistedValue: String {
        switch self {
        case .readOnly:
            "read-only"
        case .workspaceWrite:
            "workspace-write"
        case .dangerFullAccess:
            "danger-full-access"
        }
    }

    package func appServerRequestValue(style: CodexAppServerRequestValueStyle) -> String {
        switch style {
        case .configStyle:
            switch self {
            case .readOnly:
                "read-only"
            case .workspaceWrite:
                "workspace-write"
            case .dangerFullAccess:
                "danger-full-access"
            }
        case .camelCase:
            switch self {
            case .readOnly:
                "readOnly"
            case .workspaceWrite:
                "workspaceWrite"
            case .dangerFullAccess:
                "dangerFullAccess"
            }
        }
    }

    package init?(storedValue: String) {
        switch storedValue {
        case "readOnly", "read-only":
            self = .readOnly
        case "workspaceWrite", "workspace-write":
            self = .workspaceWrite
        case "dangerFullAccess", "danger-full-access":
            self = .dangerFullAccess
        default:
            return nil
        }
    }
}

package enum CodexApprovalReviewer: CaseIterable {
    case user
    case autoReview

    package var displayName: String {
        switch self {
        case .user:
            "User"
        case .autoReview:
            "Auto Review"
        }
    }

    package var persistedValue: String {
        switch self {
        case .user:
            "user"
        case .autoReview:
            "auto-review"
        }
    }

    package var appServerRequestValue: String {
        switch self {
        case .user:
            "user"
        case .autoReview:
            "auto_review"
        }
    }

    package init?(storedValue: String) {
        switch storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user":
            self = .user
        case "autoreview", "auto-review", "auto_review", "guardian_subagent", "guardiansubagent":
            self = .autoReview
        default:
            return nil
        }
    }
}
