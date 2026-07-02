import Foundation

#if REPOPROMPT_SENTRY_ENABLED
    import Sentry
#endif

enum SentryTelemetryBootstrap {
    /// Starts telemetry when the build is telemetry-enabled and a DSN is present.
    /// Must be called on the main thread (the SDK requires it).
    @MainActor
    static func start() {
        #if REPOPROMPT_SENTRY_ENABLED
            let dsn: String
            if let value = ProcessInfo.processInfo.environment["REPOPROMPT_SENTRY_DSN"], !value.isEmpty {
                dsn = value
            } else if let value = Bundle.main.object(forInfoDictionaryKey: "RepoPromptSentryDSN") as? String, !value.isEmpty {
                dsn = value
            } else {
                return
            }

            let dist = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

            SentrySDK.start { options in
                options.dsn = dsn
                #if DEBUG
                    options.environment = "debug"
                    options.debug = true
                    options.tracesSampleRate = 1
                #else
                    options.environment = "production"
                    options.debug = false
                    options.tracesSampleRate = 0.3
                #endif
                options.dist = dist
                options.add(inAppInclude: "RepoPrompt")
                options.add(inAppInclude: "RepoPromptMCP")
                options.add(inAppInclude: "RepoPromptShared")
                options.sendDefaultPii = false
                options.enableUncaughtNSExceptionReporting = true
                options.enableAppHangTracking = true
                options.enableMetricKit = false
                options.enableLogs = false
                options.maxBreadcrumbs = 50
                options.maxCacheItems = 30
                options.attachStacktrace = true
                options.enableAutoBreadcrumbTracking = false
                options.enableNetworkBreadcrumbs = false
                options.enableNetworkTracking = false
                options.enableFileIOTracing = false
                options.enableCoreDataTracing = false
                options.enableAutoPerformanceTracing = false
            }
        #endif
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
            let payload = BreadcrumbPayload(category: category, action: action, attributes: attributes())

            let breadcrumb = Breadcrumb()
            breadcrumb.category = payload.category
            breadcrumb.message = payload.message
            breadcrumb.level = .info
            if !payload.data.isEmpty {
                breadcrumb.data = payload.data
            }
            SentrySDK.addBreadcrumb(breadcrumb)
        #endif
    }

    static func increment(_ metric: Metric, value: Int = 1, attributes: @autoclosure () -> [Attribute] = []) {
        #if REPOPROMPT_SENTRY_ENABLED
            guard value > 0 else { return }
            SentrySDK.metrics.count(
                key: metric.rawValue,
                value: UInt(value),
                attributes: sentryMetricAttributes(from: attributes())
            )
        #endif
    }

    static func gauge(_ metric: Metric, value: Double, attributes: @autoclosure () -> [Attribute] = []) {
        #if REPOPROMPT_SENTRY_ENABLED
            SentrySDK.metrics.gauge(
                key: metric.rawValue,
                value: value,
                unit: nil,
                attributes: sentryMetricAttributes(from: attributes())
            )
        #endif
    }

    static func distributionMilliseconds(
        _ metric: Metric,
        value: Double,
        attributes: @autoclosure () -> [Attribute] = []
    ) {
        #if REPOPROMPT_SENTRY_ENABLED
            guard value >= 0 else { return }
            SentrySDK.metrics.distribution(
                key: metric.rawValue,
                value: value,
                unit: .millisecond,
                attributes: sentryMetricAttributes(from: attributes())
            )
        #endif
    }

    static func trace<T>(
        _ transaction: Transaction,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: () throws -> T
    ) rethrows -> T {
        #if REPOPROMPT_SENTRY_ENABLED
            let sentryTransaction = SentrySDK.startTransaction(
                name: transaction.name,
                operation: transaction.operation,
                bindToScope: false
            )
            applyAttributes(attributes(), to: sentryTransaction)
            do {
                let result = try work()
                sentryTransaction.finish(status: .ok)
                return result
            } catch {
                sentryTransaction.setTag(value: "true", key: "is_error")
                sentryTransaction.finish(status: .internalError)
                throw error
            }
        #else
            try work()
        #endif
    }

    static func traceAsync<T>(
        _ transaction: Transaction,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: () async throws -> T
    ) async rethrows -> T {
        #if REPOPROMPT_SENTRY_ENABLED
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
        #if REPOPROMPT_SENTRY_ENABLED
            let sentryTransaction = SentrySDK.startTransaction(
                name: operation.rawValue,
                operation: operation.rawValue,
                bindToScope: false
            )
            applyAttributes(attributes(), to: sentryTransaction)
            do {
                let result = try work()
                sentryTransaction.finish(status: .ok)
                return result
            } catch {
                sentryTransaction.setTag(value: "true", key: "is_error")
                sentryTransaction.finish(status: .internalError)
                throw error
            }
        #else
            try work()
        #endif
    }

    static func spanAsync<T>(
        _ operation: SpanOperation,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: (TraceSpan) async throws -> T
    ) async rethrows -> T {
        #if REPOPROMPT_SENTRY_ENABLED
            let sentryTransaction = SentrySDK.startTransaction(
                name: operation.rawValue,
                operation: operation.rawValue,
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

    static func childSpanAsync<T>(
        parent: TraceSpan,
        operation: SpanOperation,
        attributes: @autoclosure () -> [Attribute] = [],
        _ work: () async throws -> T
    ) async rethrows -> T {
        #if REPOPROMPT_SENTRY_ENABLED
            guard let parentSpan = parent.span else {
                return try await work()
            }
            let child = parentSpan.startChild(operation: operation.rawValue)
            applyAttributes(attributes(), to: child)
            do {
                let result = try await work()
                child.finish(status: .ok)
                return result
            } catch {
                child.setTag(value: "true", key: "is_error")
                child.finish(status: .internalError)
                throw error
            }
        #else
            try await work()
        #endif
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
        private static func applyAttributes(_ attributes: [Attribute], to span: Span) {
            for (key, value) in telemetryData(from: attributes) {
                span.setTag(value: value, key: key)
            }
        }

        private static func sentryMetricAttributes(from attributes: [Attribute]) -> [String: SentryAttributeValue] {
            telemetryData(from: attributes).reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value
            }
        }
    #endif
}
