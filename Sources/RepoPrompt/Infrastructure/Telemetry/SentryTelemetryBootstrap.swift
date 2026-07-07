import Foundation

#if REPOPROMPT_SENTRY_ENABLED
    import Sentry
#endif

enum SentryTelemetryBootstrap {
    /// Starts telemetry when this binary was built with Sentry support and a DSN
    /// is available. Official releases receive the DSN through Info.plist at
    /// signing time; local telemetry testing can use REPOPROMPT_SENTRY_DSN.
    @MainActor
    static func start() {
        #if REPOPROMPT_SENTRY_ENABLED
            guard let dsn = configuredDSN() else { return }
            let dist = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

            SentrySDK.start { options in
                options.dsn = dsn
                #if DEBUG
                    options.environment = "debug"
                    options.debug = true
                #else
                    options.environment = "production"
                    options.debug = false
                #endif
                options.dist = dist
                options.add(inAppInclude: "RepoPrompt")
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

    #if REPOPROMPT_SENTRY_ENABLED
        private static func configuredDSN() -> String? {
            if let value = ProcessInfo.processInfo.environment["REPOPROMPT_SENTRY_DSN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
            if let value = Bundle.main.object(forInfoDictionaryKey: "RepoPromptSentryDSN") as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
    #endif
}
