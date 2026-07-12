import Foundation

#if REPOPROMPT_SENTRY_ENABLED
    import Sentry
#endif

enum SentryTelemetryBootstrap {
    struct Status: Equatable {
        let sdkCompiledIn: Bool
        let dsnConfigured: Bool
        let telemetryEnabled: Bool
        let environmentDisabled: Bool
        let canSendTelemetry: Bool
        let started: Bool
    }

    @MainActor private static var started = false
    @MainActor private static var performanceTracingEnabled = false

    /// Starts telemetry when this binary was built with Sentry support, a DSN is
    /// available, the user has not opted out, and the process kill switch is not set.
    @MainActor
    static func start() {
        #if REPOPROMPT_SENTRY_ENABLED
            let status = currentStatus()
            guard !status.started, status.canSendTelemetry, let dsn = configuredDSN() else { return }

            performanceTracingEnabled = GlobalSettingsStore.shared.telemetryPerformanceTracingEnabled()
            let appHangReportsEnabled = GlobalSettingsStore.shared.telemetryAppHangReportsEnabled()

            SentrySDK.start { options in
                options.dsn = dsn
                #if DEBUG
                    options.environment = "debug"
                    options.debug = true
                #else
                    options.environment = "production"
                    options.debug = false
                #endif
                options.tracesSampleRate = performanceTracingEnabled ? 0.05 : 0
                // Do not let SDK defaults or future configuration attach distribution metadata.
                options.dist = nil
                options.add(inAppInclude: "RepoPrompt")
                options.add(inAppInclude: "RepoPromptMCP")
                options.add(inAppInclude: "RepoPromptShared")
                options.add(inAppInclude: "RepoPromptProcessSupport")
                options.sendDefaultPii = false
                options.enableUncaughtNSExceptionReporting = true
                options.enableAppHangTracking = appHangReportsEnabled
                options.enableMetricKit = false
                options.enableLogs = false
                options.maxBreadcrumbs = 20
                options.maxCacheItems = 10
                options.attachStacktrace = true
                options.enableAutoBreadcrumbTracking = false
                options.enableNetworkBreadcrumbs = false
                options.enableNetworkTracking = false
                options.enableFileIOTracing = false
                options.enableCoreDataTracing = false
                options.enableAutoPerformanceTracing = false
                options.enableCaptureFailedRequests = false
                options.enableAutoSessionTracking = false
                options.beforeSend = { event in
                    scrub(event: event)
                }
            }
            started = true
        #endif
    }

    @MainActor
    static func currentStatus() -> Status {
        #if REPOPROMPT_SENTRY_ENABLED
            let dsnConfigured = configuredDSN() != nil
            let telemetryEnabled = GlobalSettingsStore.shared.telemetryEnabled()
            let environmentDisabled = isEnvironmentDisabled()
            return Status(
                sdkCompiledIn: true,
                dsnConfigured: dsnConfigured,
                telemetryEnabled: telemetryEnabled,
                environmentDisabled: environmentDisabled,
                canSendTelemetry: dsnConfigured && telemetryEnabled && !environmentDisabled,
                started: started
            )
        #else
            return Status(
                sdkCompiledIn: false,
                dsnConfigured: false,
                telemetryEnabled: false,
                environmentDisabled: isEnvironmentDisabled(),
                canSendTelemetry: false,
                started: false
            )
        #endif
    }

    @MainActor
    static func disableAndClose() {
        #if REPOPROMPT_SENTRY_ENABLED
            performanceTracingEnabled = false
            guard started else { return }
            SentrySDK.close()
            started = false
            // Sentry Cocoa does not expose a stable public API in 9.17.1 for selectively
            // deleting already-persisted envelope cache items. Closing the SDK stops new
            // captures in-process; the small cache limit above bounds any queued leftovers.
        #endif
    }

    @MainActor
    static func restartIfStarted() {
        #if REPOPROMPT_SENTRY_ENABLED
            guard started else { return }
            disableAndClose()
            start()
        #endif
    }

    #if REPOPROMPT_SENTRY_ENABLED
        private static func configuredDSN() -> String? {
            #if DEBUG
                if let value = ProcessInfo.processInfo.environment["REPOPROMPT_SENTRY_DSN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty
                {
                    return value
                }
            #endif
            if let value = Bundle.main.object(forInfoDictionaryKey: "RepoPromptSentryDSN") as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
    #endif

    private static func isEnvironmentDisabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["REPOPROMPT_TELEMETRY_DISABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["1", "true", "yes", "on"].contains(value ?? "")
    }

    struct TraceSpan {
        #if REPOPROMPT_SENTRY_ENABLED
            fileprivate let span: Span?

            fileprivate init(_ span: Span?) {
                self.span = span
            }
        #else
            fileprivate init() {}
        #endif
    }

    static func addBreadcrumb(_ category: Category, action: Action, attributes: @autoclosure () -> [Attribute] = []) {
        #if REPOPROMPT_SENTRY_ENABLED
            guard isAllowedStartupBreadcrumb(category: category, action: action) else { return }
            let payload = BreadcrumbPayload(category: category, action: action, attributes: attributes())
            Task { @MainActor in
                guard started else { return }
                let breadcrumb = Breadcrumb(level: .info, category: payload.category)
                breadcrumb.message = payload.message
                breadcrumb.data = payload.data
                SentrySDK.addBreadcrumb(breadcrumb)
            }
        #endif
    }

    static func increment(_ metric: Metric, value: Int = 1, attributes: @autoclosure () -> [Attribute] = []) {
        // Manual metrics deferred pending a less fragile telemetry design.
    }

    static func gauge(_ metric: Metric, value: Double, attributes: @autoclosure () -> [Attribute] = []) {
        // Manual metrics deferred pending a less fragile telemetry design.
    }

    static func distributionMilliseconds(
        _ metric: Metric,
        value: Double,
        attributes: @autoclosure () -> [Attribute] = []
    ) {
        // Manual metrics deferred pending a less fragile telemetry design.
    }

    static func trace<T>(
        _ transaction: Transaction,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: () throws -> T
    ) rethrows -> T {
        try work()
    }

    static func traceAsync<T>(
        _ transaction: Transaction,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: () async throws -> T
    ) async rethrows -> T {
        #if REPOPROMPT_SENTRY_ENABLED
            guard await shouldTrace(transaction) else { return try await work() }
            let sentryTransaction = SentrySDK.startTransaction(
                name: transaction.name,
                operation: transaction.operation,
                bindToScope: false
            )
            applyAttributes(attributes(), to: sentryTransaction)
            do {
                let result = try await work()
                sentryTransaction.finish(status: .ok)
                return result
            } catch {
                sentryTransaction.setTag(value: "true", key: "is_error")
                sentryTransaction.finish(status: .internalError)
                throw error
            }
        #else
            try await work()
        #endif
    }

    static func traceAsync<T>(
        _ transaction: Transaction,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: (TraceSpan) async throws -> T
    ) async rethrows -> T {
        #if REPOPROMPT_SENTRY_ENABLED
            guard await shouldTrace(transaction) else { return try await work(TraceSpan(nil)) }
            let sentryTransaction = SentrySDK.startTransaction(
                name: transaction.name,
                operation: transaction.operation,
                bindToScope: false
            )
            applyAttributes(attributes(), to: sentryTransaction)
            do {
                let result = try await work(TraceSpan(sentryTransaction))
                sentryTransaction.finish(status: .ok)
                return result
            } catch {
                sentryTransaction.setTag(value: "true", key: "is_error")
                sentryTransaction.finish(status: .internalError)
                throw error
            }
        #else
            try await work(TraceSpan())
        #endif
    }

    static func span<T>(
        _ operation: SpanOperation,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: () throws -> T
    ) rethrows -> T {
        try work()
    }

    static func spanAsync<T>(
        _ operation: SpanOperation,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: (TraceSpan) async throws -> T
    ) async rethrows -> T {
        #if REPOPROMPT_SENTRY_ENABLED
            try await work(TraceSpan(nil))
        #else
            try await work(TraceSpan())
        #endif
    }

    static func childSpanAsync<T>(
        parent: TraceSpan,
        operation: SpanOperation,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: () async throws -> T
    ) async rethrows -> T {
        try await work()
    }

    private struct BreadcrumbPayload {
        let category: String
        let message: String
        let data: [String: String]

        init(category: Category, action: Action, attributes: [Attribute]) {
            self.category = category.rawValue
            message = action.rawValue
            data = telemetryData(from: attributes + [.action(action)])
        }
    }

    #if REPOPROMPT_SENTRY_ENABLED
        @MainActor
        private static func shouldTrace(_ transaction: Transaction) -> Bool {
            started && performanceTracingEnabled && transaction.isStartupTrace
        }

        private static func applyAttributes(_ attributes: [Attribute], to span: Span) {
            for (key, value) in telemetryData(from: attributes) {
                span.setTag(value: value, key: key)
            }
        }

        private static func isAllowedStartupBreadcrumb(category: Category, action: Action) -> Bool {
            switch (category, action) {
            case (.appLifecycle, .appInitialized), (.mcpBootstrap, .mcpServerStarted):
                true
            default:
                false
            }
        }

        private static func scrub(event: Event) -> Event? {
            event.user = nil
            event.request = nil
            event.serverName = nil
            if let message = event.message {
                event.message = SentryMessage(formatted: scrubString(message.formatted))
                event.message?.message = message.message.map(scrubString)
                event.message?.params = message.params?.map(scrubString)
            }
            event.exceptions = event.exceptions?.map { exception in
                exception.value = exception.value.map(scrubString)
                exception.type = exception.type.map(scrubString)
                exception.module = exception.module.map(scrubString)
                return exception
            }
            event.tags = event.tags?.reduce(into: [:]) { result, entry in
                if let value = scrubValue(entry.value, keyPath: [entry.key]) as? String {
                    result[entry.key] = value
                }
            }
            event.context = event.context?.reduce(into: [:]) { result, entry in
                guard !shouldDropValue(at: [entry.key]) else { return }
                let context: [String: Any] = entry.value.reduce(into: [:]) { contextResult, contextEntry in
                    guard let contextKey = contextEntry.key as? String else { return }
                    if let value = scrubValue(contextEntry.value, keyPath: [entry.key, contextKey]) {
                        contextResult[contextKey] = value
                    }
                }
                if !context.isEmpty {
                    result[entry.key] = context
                }
            }
            event.extra = event.extra?.reduce(into: [:]) { result, entry in
                if let value = scrubValue(entry.value, keyPath: [entry.key]) {
                    result[entry.key] = value
                }
            }
            event.breadcrumbs = event.breadcrumbs?.map { breadcrumb in
                breadcrumb.message = breadcrumb.message.map(scrubString)
                if let data = breadcrumb.data {
                    breadcrumb.data = data.reduce(into: [:]) { result, entry in
                        if let value = scrubValue(entry.value, keyPath: [entry.key]) {
                            result[entry.key] = value
                        }
                    }
                }
                return breadcrumb
            }
            return event
        }
    #endif

    static func scrubPayloadForTesting(_ value: [String: Any]) -> [String: Any] {
        value.reduce(into: [:]) { result, entry in
            if let value = scrubValue(entry.value, keyPath: [entry.key]) {
                result[entry.key] = value
            }
        }
    }

    private static func scrubValue(_ value: Any, keyPath: [String]) -> Any? {
        guard !shouldDropValue(at: keyPath) else { return nil }
        if let string = value as? String {
            return scrubString(string)
        } else if let dictionary = value as? [String: Any] {
            let scrubbed = dictionary.reduce(into: [:]) { result, entry in
                if let value = scrubValue(entry.value, keyPath: keyPath + [entry.key]) {
                    result[entry.key] = value
                }
            }
            return scrubbed.isEmpty ? nil : scrubbed
        } else if let array = value as? [Any] {
            return array.compactMap { scrubValue($0, keyPath: keyPath) }
        } else {
            return value
        }
    }

    private static func shouldDropValue(at keyPath: [String]) -> Bool {
        let components = keyPath.map(normalizedTelemetryKey)
        guard let leaf = components.last else { return false }

        if components.contains(where: requestPayloadKeys.contains) {
            return true
        }
        if components.contains("geo") || geoPayloadKeys.contains(leaf) {
            return true
        }
        if components.contains("user") || userIdentifierKeys.contains(leaf) {
            return true
        }
        if components.contains("device"), deviceIdentifierKeys.contains(leaf) {
            return true
        }
        if stableIdentifierKeys.contains(leaf) {
            return true
        }
        return false
    }

    private static let requestPayloadKeys: Set<String> = [
        "request",
        "http",
        "headers",
        "cookies",
        "cookie",
        "query",
        "query_string",
        "body",
        "url"
    ]

    private static let geoPayloadKeys: Set<String> = [
        "city",
        "region",
        "country_code",
        "latitude",
        "longitude",
        "location",
        "user_geo"
    ]

    private static let userIdentifierKeys: Set<String> = [
        "user_id",
        "userid",
        "username",
        "email",
        "ip_address",
        "ipaddress"
    ]

    private static let deviceIdentifierKeys: Set<String> = [
        "id",
        "name",
        "identifier",
        "unique_id",
        "uniqueid"
    ]

    private static let stableIdentifierKeys: Set<String> = [
        "server_name",
        "servername",
        "vendor_id",
        "vendorid",
        "identifier_for_vendor",
        "identifierforvendor",
        "advertising_id",
        "advertisingid",
        "installation_id",
        "installationid",
        "device_app_hash",
        "deviceapphash"
    ]

    private static func normalizedTelemetryKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    static func scrubStringForTesting(_ value: String) -> String {
        scrubString(value)
    }

    private static func scrubString(_ value: String) -> String {
        var redacted = value
        let home = NSHomeDirectory()
        if !home.isEmpty {
            redacted = redacted.replacingOccurrences(of: home, with: "~")
        }
        let username = NSUserName()
        if !username.isEmpty {
            redacted = redacted.replacingOccurrences(of: "/Users/\(username)", with: "~/")
        }
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(api[_-]?key|token|secret|password|authorization)[=: ]+(?:(?:bearer|basic|token|dsn)\s+)?[^\s,;]+"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#,
            with: "[redacted]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#,
            with: "[ip]",
            options: .regularExpression
        )
        return redacted
    }
}

private extension SentryTelemetryBootstrap.Transaction {
    var isStartupTrace: Bool {
        switch self {
        case .appLaunch, .mcpServerStart:
            true
        case .agentRun, .contextBuilderRun, .mcpBootstrapAdmission, .mcpToolCall, .workspaceAction:
            false
        }
    }
}
