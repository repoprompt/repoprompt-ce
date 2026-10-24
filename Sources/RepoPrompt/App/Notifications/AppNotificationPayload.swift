import Foundation

/// Kind of an app notification. Raw values are part of the `userInfo` contract.
enum AppNotificationKind: String, CaseIterable {
    case interaction
    case turnComplete = "turn_complete"
    case turnFailed = "turn_failed"
    case chatComplete = "chat_complete"
    case contextBuilderComplete = "context_builder_complete"
    case feedback
}

/// Identity of the running process. Notifications carry it so actions delivered by a notification
/// posted from a previous launch can never resolve anything in this one.
enum AppNotificationLaunchIdentity {
    static let current = UUID()
}

/// Versioned notification payload stored in `UNNotificationContent.userInfo`.
///
/// Payload v2 is additive: it keeps the route v1 keys (`rp_route_kind`, `rp_route_version`,
/// `workspace_id`, `tab_id`, `session_id`, `window_id`) untouched so route parsing keeps working
/// for notifications delivered by older builds and vice versa.
struct AppNotificationPayload: Equatable {
    static let currentVersion = 2

    struct InteractionReference: Equatable {
        let id: UUID
        let kind: AgentPendingInteractionKind
        let fingerprint: String
        let choiceCount: Int

        init(id: UUID, kind: AgentPendingInteractionKind, fingerprint: String, choiceCount: Int = 0) {
            self.id = id
            self.kind = kind
            self.fingerprint = fingerprint
            self.choiceCount = choiceCount
        }
    }

    let kind: AppNotificationKind
    let route: AgentSessionDeepLinkRoute?
    let launchID: UUID
    let interaction: InteractionReference?
    /// Identity of the finished turn a turn-complete notification describes (see
    /// `AgentNotificationTurnMarker`), so a late Reply cannot target a newer turn.
    let turnMarker: String?
    let postedAt: Date

    init(
        kind: AppNotificationKind,
        route: AgentSessionDeepLinkRoute?,
        launchID: UUID = AppNotificationLaunchIdentity.current,
        interaction: InteractionReference? = nil,
        turnMarker: String? = nil,
        postedAt: Date = Date()
    ) {
        self.kind = kind
        self.route = route
        self.launchID = launchID
        self.interaction = interaction
        self.turnMarker = turnMarker
        self.postedAt = postedAt
    }

    var isFromCurrentLaunch: Bool {
        launchID == AppNotificationLaunchIdentity.current
    }

    var userInfo: [AnyHashable: Any] {
        var userInfo = route?.notificationUserInfo ?? [:]
        userInfo[Key.payloadVersion] = Self.currentVersion
        userInfo[Key.kind] = kind.rawValue
        userInfo[Key.launchID] = launchID.uuidString
        userInfo[Key.postedAt] = postedAt.timeIntervalSince1970
        if let interaction {
            userInfo[AppDeepLinkRouteUserInfoKey.interactionID] = interaction.id.uuidString
            userInfo[Key.interactionKind] = interaction.kind.rawValue
            userInfo[Key.interactionFingerprint] = interaction.fingerprint
            userInfo[Key.choiceCount] = interaction.choiceCount
        }
        if let turnMarker {
            userInfo[Key.turnMarker] = turnMarker
        }
        return userInfo
    }

    /// Parses a v2+ payload. Returns `nil` for v1-only payloads (use
    /// `AgentSessionDeepLinkRoute.parse(notificationUserInfo:)` for those) and for malformed input.
    /// Future versions degrade to their route plus kind: interaction references are only trusted at
    /// the version this build understands.
    static func parse(_ userInfo: [AnyHashable: Any]) -> AppNotificationPayload? {
        let reader = NotificationUserInfoReader(userInfo)
        guard let version = reader.int(Key.payloadVersion), version >= currentVersion,
              let kind = reader.string(Key.kind).flatMap(AppNotificationKind.init(rawValue:)),
              let launchID = reader.uuid(Key.launchID)
        else {
            return nil
        }
        let route = AgentSessionDeepLinkRoute.parse(notificationUserInfo: userInfo)
        let postedAt = reader.double(Key.postedAt).map(Date.init(timeIntervalSince1970:)) ?? .distantPast

        var interaction: InteractionReference?
        if version == currentVersion,
           let id = reader.uuid(AppDeepLinkRouteUserInfoKey.interactionID),
           let interactionKind = reader.string(Key.interactionKind).flatMap(AgentPendingInteractionKind.init(rawValue:)),
           let fingerprint = reader.string(Key.interactionFingerprint),
           !fingerprint.isEmpty
        {
            interaction = InteractionReference(
                id: id,
                kind: interactionKind,
                fingerprint: fingerprint,
                choiceCount: max(0, reader.int(Key.choiceCount) ?? 0)
            )
        }
        return AppNotificationPayload(
            kind: kind,
            route: route,
            launchID: launchID,
            interaction: interaction,
            turnMarker: reader.string(Key.turnMarker),
            postedAt: postedAt
        )
    }

    enum Key {
        static let payloadVersion = "rp_payload_version"
        static let kind = "rp_notification_kind"
        static let launchID = "rp_launch_id"
        static let postedAt = "posted_at"
        static let interactionKind = "interaction_kind"
        static let interactionFingerprint = "interaction_fp"
        static let choiceCount = "choice_count"
        static let turnMarker = "turn_marker"
    }
}

/// Stable notification request and thread identifiers.
///
/// Stable identifiers make re-posting replace a delivered notification instead of stacking a new one,
/// and let the app retract a notification when its interaction resolves elsewhere.
enum AppNotificationIdentifier {
    static let prefix = "rp."

    static func interaction(_ interactionID: UUID) -> String {
        "rp.agent.interaction.\(interactionID.uuidString)"
    }

    static func turnComplete(tabID: UUID) -> String {
        "rp.agent.turn.\(tabID.uuidString)"
    }

    static func turnFailed(tabID: UUID) -> String {
        "rp.agent.failure.\(tabID.uuidString)"
    }

    static func feedback(_ id: UUID) -> String {
        "rp.feedback.\(id.uuidString)"
    }

    static func chatComplete(tabID: UUID?) -> String {
        "rp.chat.\((tabID ?? UUID()).uuidString)"
    }

    static func contextBuilderComplete(tabID: UUID?) -> String {
        "rp.cb.\((tabID ?? UUID()).uuidString)"
    }

    static func sessionThread(tabID: UUID, sessionID: UUID?) -> String {
        "rp.agent.session.\((sessionID ?? tabID).uuidString)"
    }

    static func composeThread(tabID: UUID?) -> String {
        tabID.map { "rp.compose.\($0.uuidString)" } ?? "rp.compose"
    }
}
