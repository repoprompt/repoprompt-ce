// MARK: - DEBUG Sparkle Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugSparkleStatusPayload(op: String) async -> CallTool.Result {
            let feedURLString = Bundle.main.infoDictionary?["SUFeedURL"] as? String
            let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            var payload: [String: Any] = [
                "ok": true,
                "op": op,
                "feed_url": feedURLString ?? NSNull(),
                "expected_feed_url": SparkleUpdaterManager.debugExpectedFeedURL,
                "feed_url_matches_expected": feedURLString.map { SparkleUpdaterManager.debugFeedURLMatchesExpected($0) } ?? NSNull(),
                "current_bundle_short_version": shortVersion ?? NSNull(),
                "current_bundle_build": buildVersion ?? NSNull(),
                "sparkle_last_update_check": debugDefaultsEntry(
                    key: SparkleUpdaterManager.debugLastCheckKey,
                    object: UserDefaults.standard.object(forKey: SparkleUpdaterManager.debugLastCheckKey)
                ),
                "passive_appcast_checks": debugDefaultsEntry(
                    key: SparkleUpdaterManager.debugPassiveAppcastChecksKey,
                    object: UserDefaults.standard.object(forKey: SparkleUpdaterManager.debugPassiveAppcastChecksKey)
                )
            ]

            let managerSnapshot = await MainActor.run { () -> [String: Any]? in
                guard let manager = SparkleUpdaterManager.shared else { return nil }
                return manager.debugPublishedSnapshot()
            }
            if let managerSnapshot {
                payload["manager_present"] = true
                for (key, value) in managerSnapshot {
                    payload[key] = value
                }
            } else {
                payload["manager_present"] = false
                payload["sparkle_configuration_valid"] = NSNull()
                payload["updates_disabled_message"] = NSNull()
                payload["can_check_for_updates"] = NSNull()
                payload["sparkle_can_check_for_updates"] = NSNull()
                payload["passive_appcast_checks_enabled"] = NSNull()
                payload["sparkle_automatically_checks_for_updates"] = NSNull()
                payload["update_available"] = NSNull()
                payload["update_version"] = NSNull()
                payload["update_date_epoch"] = NSNull()
                payload["update_date_present"] = NSNull()
                payload["update_description_present"] = NSNull()
                payload["appcast_task_present"] = NSNull()
                payload["appcast_task_cancelled"] = NSNull()
            }

            return debugDiagnosticsResult(payload)
        }

        func debugSparkleAppcastRequestPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            switch debugResolveSparkleFeedURL(op: op, arguments: arguments) {
            case let .failed(result):
                return result
            case let .resolved(feedURL, overrideUsed):
                let request = SparkleUpdaterManager.makePassiveAppcastRequest(feedURL: feedURL)
                let headers = request.allHTTPHeaderFields ?? [:]
                let expectedHeaders = [
                    "Cache-Control": "no-cache",
                    "Pragma": "no-cache"
                ]
                let matchesExpected = request.url == feedURL
                    && request.timeoutInterval == 15
                    && request.cachePolicy == .reloadIgnoringLocalCacheData
                    && expectedHeaders.allSatisfy { headers[$0.key] == $0.value }
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "feed_url_override_used": overrideUsed,
                    "url": request.url?.absoluteString ?? NSNull(),
                    "feed_url_matches_expected": SparkleUpdaterManager.debugFeedURLMatchesExpected(feedURL.absoluteString),
                    "timeout": request.timeoutInterval,
                    "cache_policy": [
                        "raw": request.cachePolicy.rawValue,
                        "name": debugCachePolicyName(request.cachePolicy)
                    ],
                    "headers": headers,
                    "expected": [
                        "timeout": 15,
                        "cache_policy": [
                            "raw": URLRequest.CachePolicy.reloadIgnoringLocalCacheData.rawValue,
                            "name": debugCachePolicyName(.reloadIgnoringLocalCacheData)
                        ],
                        "headers": expectedHeaders
                    ],
                    "matches_expected": matchesExpected
                ])
            }
        }

        func debugSparkleFetchAppcastPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            switch debugResolveSparkleFeedURL(op: op, arguments: arguments) {
            case let .failed(result):
                return result
            case let .resolved(feedURL, overrideUsed):
                if overrideUsed, debugBool(arguments, "allow_external_fetch") != true {
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "sparkle_fetch_appcast with feed_url_override requires allow_external_fetch=true because it fetches an arbitrary HTTPS URL.")
                }
                let started = Date()
                let latestVersion = await SparkleUpdaterManager.testFetchAndParseAppcastVersion(
                    feedURL: feedURL,
                    httpClient: DefaultHTTPClient.uiCriticalClient
                )
                let durationMS = Int(Date().timeIntervalSince(started) * 1000)
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                var payload: [String: Any] = [
                    "ok": true,
                    "op": op,
                    "feed_url_override_used": overrideUsed,
                    "feed_url": feedURL.absoluteString,
                    "fetch_succeeded": latestVersion != nil,
                    "parsed_latest_version": latestVersion ?? NSNull(),
                    "current_version": currentVersion,
                    "duration_ms": durationMS
                ]
                if let latestVersion {
                    payload["comparison_is_newer"] = SparkleUpdaterManager.debugIsVersion(latestVersion, newerThan: currentVersion)
                } else {
                    payload["comparison_is_newer"] = NSNull()
                }
                return debugDiagnosticsResult(payload)
            }
        }

        func debugSparklePassiveCheckDryRunPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let forceResultProvided = arguments["force_check_result"] != nil
            let forcedResult = debugBool(arguments, "force_check_result")
            if forceResultProvided, forcedResult == nil {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "force_check_result must be a boolean when provided.")
            }

            let nowEpoch: Double
            if arguments["now_epoch"] != nil {
                guard let parsed = debugDouble(arguments, "now_epoch"), parsed.isFinite else {
                    return debugDiagnosticsError(op: op, code: "invalid_params", message: "now_epoch must be a finite number when provided.")
                }
                nowEpoch = parsed
            } else {
                nowEpoch = Date().timeIntervalSince1970
            }

            let feedURL: URL?
            let overrideUsed: Bool
            if arguments["feed_url_override"] != nil || forcedResult == nil {
                switch debugResolveSparkleFeedURL(op: op, arguments: arguments) {
                case let .failed(result):
                    return result
                case let .resolved(resolvedURL, resolvedOverrideUsed):
                    if resolvedOverrideUsed, forcedResult == nil, debugBool(arguments, "allow_external_fetch") != true {
                        return debugDiagnosticsError(op: op, code: "invalid_params", message: "sparkle_passive_check_dry_run live fetch with feed_url_override requires allow_external_fetch=true because it fetches an arbitrary HTTPS URL.")
                    }
                    feedURL = resolvedURL
                    overrideUsed = resolvedOverrideUsed
                }
            } else {
                feedURL = nil
                overrideUsed = false
            }

            let suiteName = "com.repoprompt.sparkledebug.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return debugDiagnosticsError(op: op, code: "internal_error", message: "Unable to create ephemeral UserDefaults suite.")
            }
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }

            let lastCheckKey = SparkleUpdaterManager.debugLastCheckKey
            let standardBeforeObject = UserDefaults.standard.object(forKey: lastCheckKey)
            let checkMode = forcedResult == nil ? "live_fetch" : "forced"
            let succeeded = await SparkleUpdaterManager.performPassiveAppcastCheck(
                check: {
                    if let forcedResult {
                        return forcedResult
                    }
                    guard let feedURL else { return false }
                    return await SparkleUpdaterManager.testFetchAndParseAppcastVersion(
                        feedURL: feedURL,
                        httpClient: DefaultHTTPClient.uiCriticalClient
                    ) != nil
                },
                now: Date(timeIntervalSince1970: nowEpoch),
                defaults: defaults
            )
            let standardAfterObject = UserDefaults.standard.object(forKey: lastCheckKey)
            let suiteLastCheckObject = defaults.object(forKey: lastCheckKey)

            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "suite_name": suiteName,
                "check_mode": checkMode,
                "force_check_result": forcedResult ?? NSNull(),
                "feed_url_override_used": overrideUsed,
                "feed_url": feedURL?.absoluteString ?? NSNull(),
                "now_epoch": nowEpoch,
                "succeeded": succeeded,
                "wrote_timestamp": suiteLastCheckObject != nil,
                "suite_last_check_epoch": debugDefaultsEpochValue(suiteLastCheckObject) ?? NSNull(),
                "real_last_check_before": debugDefaultsEntry(key: lastCheckKey, object: standardBeforeObject),
                "real_last_check_after": debugDefaultsEntry(key: lastCheckKey, object: standardAfterObject),
                "real_last_check_unchanged": debugDefaultsObjectsEqual(standardBeforeObject, standardAfterObject)
            ])
        }

        func debugSparkleTriggerPassiveCheckPayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            guard debugBool(arguments, "allow_destructive") == true else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "sparkle_trigger_passive_check requires allow_destructive=true because it writes the real SparkleLastUpdateCheck on success.")
            }

            guard let manager = await MainActor.run(body: { SparkleUpdaterManager.shared }) else {
                return debugDiagnosticsError(op: op, code: "unavailable", message: "SparkleUpdaterManager.shared is not initialized.")
            }

            let lastCheckKey = SparkleUpdaterManager.debugLastCheckKey
            let beforeObject = UserDefaults.standard.object(forKey: lastCheckKey)
            let succeeded = await manager.debugTriggerPassiveCheck()
            let afterObject = UserDefaults.standard.object(forKey: lastCheckKey)
            let updateStateAfter = await MainActor.run {
                manager.debugPublishedSnapshot()
            }

            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "succeeded": succeeded,
                "wrote_timestamp": !debugDefaultsObjectsEqual(beforeObject, afterObject),
                "previous_last_check": debugDefaultsEntry(key: lastCheckKey, object: beforeObject),
                "current_last_check": debugDefaultsEntry(key: lastCheckKey, object: afterObject),
                "update_state_after": updateStateAfter
            ])
        }

        private enum DebugSparkleFeedURLResolution {
            case resolved(URL, Bool)
            case failed(CallTool.Result)
        }

        private func debugResolveSparkleFeedURL(op: String, arguments: [String: Value]) -> DebugSparkleFeedURLResolution {
            if arguments["feed_url_override"] != nil {
                guard let override = debugString(arguments, "feed_url_override") else {
                    return .failed(debugDiagnosticsError(op: op, code: "invalid_params", message: "feed_url_override must be a string when provided."))
                }
                let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: trimmed),
                      url.scheme?.lowercased() == "https",
                      url.host?.isEmpty == false
                else {
                    return .failed(debugDiagnosticsError(op: op, code: "invalid_params", message: "feed_url_override must be a valid HTTPS URL. Overrides are transient and are never persisted."))
                }
                return .resolved(url, true)
            }

            guard let rawFeedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
                  let url = URL(string: rawFeedURL)
            else {
                return .failed(debugDiagnosticsError(op: op, code: "unavailable", message: "Info.plist SUFeedURL is missing or invalid."))
            }
            return .resolved(url, false)
        }

        private func debugCachePolicyName(_ policy: URLRequest.CachePolicy) -> String {
            switch policy {
            case .useProtocolCachePolicy:
                return "useProtocolCachePolicy"
            case .reloadIgnoringLocalCacheData:
                return "reloadIgnoringLocalCacheData"
            case .reloadIgnoringLocalAndRemoteCacheData:
                return "reloadIgnoringLocalAndRemoteCacheData"
            case .returnCacheDataElseLoad:
                return "returnCacheDataElseLoad"
            case .returnCacheDataDontLoad:
                return "returnCacheDataDontLoad"
            case .reloadRevalidatingCacheData:
                return "reloadRevalidatingCacheData"
            @unknown default:
                return "unknown"
            }
        }

        private func debugDefaultsEntry(key: String, object: Any?) -> [String: Any] {
            var entry: [String: Any] = [
                "key": key,
                "object_present": object != nil
            ]
            guard let object else {
                entry["type"] = NSNull()
                entry["value"] = NSNull()
                return entry
            }

            switch object {
            case let number as NSNumber:
                let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
                entry["type"] = isBool ? "bool" : "number"
                entry["value"] = isBool ? number.boolValue : number.doubleValue
                entry["double_value"] = number.doubleValue
            case let date as Date:
                entry["type"] = "date"
                entry["value"] = date.timeIntervalSince1970
                entry["double_value"] = date.timeIntervalSince1970
            case let string as String:
                entry["type"] = "string"
                entry["value"] = string
                if let double = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    entry["double_value"] = double
                }
            case let bool as Bool:
                entry["type"] = "bool"
                entry["value"] = bool
                entry["double_value"] = bool ? 1 : 0
            default:
                entry["type"] = String(describing: type(of: object))
                entry["value"] = String(describing: object)
            }
            return entry
        }

        private func debugDefaultsEpochValue(_ object: Any?) -> Double? {
            switch object {
            case let number as NSNumber:
                number.doubleValue
            case let date as Date:
                date.timeIntervalSince1970
            case let string as String:
                Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                nil
            }
        }

        private func debugDefaultsObjectsEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                true
            case let (left as NSNumber, right as NSNumber):
                left.isEqual(to: right)
            case let (left as Date, right as Date):
                left == right
            case let (left as String, right as String):
                left == right
            case let (left as Bool, right as Bool):
                left == right
            case let (left?, right?):
                String(describing: type(of: left)) == String(describing: type(of: right))
                    && String(describing: left) == String(describing: right)
            default:
                false
            }
        }
    }
#endif
