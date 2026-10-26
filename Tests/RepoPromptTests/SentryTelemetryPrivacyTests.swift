@testable import RepoPromptApp
import XCTest

#if REPOPROMPT_SENTRY_ENABLED
    @_spi(Private) import Sentry
#endif

final class SentryTelemetryPrivacyTests: XCTestCase {
    func testSerializedCrashEventScrubsTypedDataAndPreservesSymbolication() throws {
        #if REPOPROMPT_SENTRY_ENABLED
            let frame = Frame()
            frame.fileName = "/Users/privacy-user-sentinel/project/Private.swift"
            frame.package = "/Users/privacy-user-sentinel/private-plugin.bundle"
            frame.function = "load token=payload-secret-sentinel"
            frame.instructionAddress = "0x0000000100001234"
            frame.imageAddress = "0x0000000100000000"
            frame.contextLine = "authorization: Bearer payload-secret-sentinel"
            frame.vars = ["password": "payload-secret-sentinel", "safe_code": 42]
            let systemFrame = Frame()
            systemFrame.package = "/System/Library/Frameworks/AppKit.framework/AppKit"
            let stacktrace = SentryStacktrace(frames: [frame, systemFrame], registers: ["pc": "0x0000000100001234"])
            let thread = SentryThread(threadId: NSNumber(value: 1))
            thread.name = "worker /Users/privacy-user-sentinel/project"
            thread.crashed = true
            thread.stacktrace = stacktrace
            let exception = Exception(value: "failure token=payload-secret-sentinel at 192.0.2.42", type: "CrashFixture")
            exception.stacktrace = stacktrace
            let mechanism = Mechanism(type: "signal")
            mechanism.handled = false
            mechanism.desc = "failure /Users/privacy-user-sentinel/project"
            mechanism.helpLink = "file:///Users/privacy-user-sentinel/private-help.html"
            mechanism.data = ["token": "payload-secret-sentinel", "safe_code": 42]
            let meta = MechanismContext()
            meta.signal = ["name": "SIGABRT", "detail": "token=payload-secret-sentinel"]
            mechanism.meta = meta
            exception.mechanism = mechanism
            let image = DebugMeta()
            image.type = "macho"
            image.debugID = "01234567-89AB-CDEF-0123-456789ABCDEF"
            image.imageAddress = "0x0000000100000000"
            image.imageSize = NSNumber(value: 4096)
            image.codeFile = "/Users/privacy-user-sentinel/private-plugin.bundle"
            let event = Event(level: .fatal)
            event.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            event.dist = "distribution-sentinel"
            event.stacktrace = stacktrace
            event.threads = [thread]
            event.exceptions = [exception]
            event.debugMeta = [image]

            let payload = try scrubAndSerialize(event, forbidden: [
                "privacy-user-sentinel", "private-plugin.bundle", "payload-secret-sentinel", "192.0.2.42", "distribution-sentinel"
            ])
            XCTAssertNil(payload["dist"])
            let serializedStack = try XCTUnwrap(payload["stacktrace"] as? [String: Any])
            let frames = try XCTUnwrap(serializedStack["frames"] as? [[String: Any]])
            XCTAssertEqual(frames.count, 2)
            let firstFrame = try XCTUnwrap(frames.first)
            XCTAssertNil(firstFrame["filename"])
            XCTAssertNil(firstFrame["package"])
            XCTAssertEqual(firstFrame["instruction_addr"] as? String, "0x0000000100001234")
            XCTAssertEqual(firstFrame["image_addr"] as? String, "0x0000000100000000")
            XCTAssertEqual(frames.last?["package"] as? String, "/System/Library/Frameworks/AppKit.framework/AppKit")
            let threads = try XCTUnwrap(payload["threads"] as? [String: Any])
            let threadValues = try XCTUnwrap(threads["values"] as? [[String: Any]])
            XCTAssertEqual(threadValues.first?["crashed"] as? Bool, true)
            let exceptions = try XCTUnwrap(payload["exception"] as? [String: Any])
            let exceptionValues = try XCTUnwrap(exceptions["values"] as? [[String: Any]])
            XCTAssertEqual(exceptionValues.first?["type"] as? String, "CrashFixture")
            let serializedMechanism = try XCTUnwrap(exceptionValues.first?["mechanism"] as? [String: Any])
            XCTAssertEqual(serializedMechanism["handled"] as? Bool, false)
            XCTAssertEqual(serializedMechanism["data"] as? [String: Int], ["safe_code": 42])
            let debugMeta = try XCTUnwrap(payload["debug_meta"] as? [String: Any])
            let images = try XCTUnwrap(debugMeta["images"] as? [[String: Any]])
            let firstImage = try XCTUnwrap(images.first)
            XCTAssertNil(firstImage["code_file"])
            XCTAssertEqual(firstImage["debug_id"] as? String, "01234567-89AB-CDEF-0123-456789ABCDEF")
            XCTAssertEqual(firstImage["image_addr"] as? String, "0x0000000100000000")
            XCTAssertEqual(firstImage["image_size"] as? Int, 4096)
        #else
            try skipWithoutSentry()
        #endif
    }

    func testSerializedEventRemovesIdentifiersAndNestedPayloadsWithoutDroppingSafeDiagnostics() throws {
        #if REPOPROMPT_SENTRY_ENABLED
            let event = Event(level: .error)
            event.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            event.user = User(userId: "user-identity-sentinel")
            let request = SentryRequest()
            request.url = "https://example.invalid/request-sentinel"
            event.request = request
            event.serverName = "server-identity-sentinel"
            event.message = SentryMessage(formatted: "token=payload-secret-sentinel at /Users/privacy-user-sentinel/project")
            event.message?.params = ["authorization: Bearer payload-secret-sentinel"]
            event.tags = ["authorization": "payload-secret-sentinel", "safe_tag": "startup"]
            event.context = [
                "device": ["name": "device-identity-sentinel", "arch": "arm64"],
                "geo": ["city": "geo-identity-sentinel"],
                "runtime": ["name": "macOS"]
            ]
            event.extra = ["nested": [["headers": ["Authorization": "payload-secret-sentinel"], "safe_code": 42]]]
            let breadcrumb = Breadcrumb(level: .info, category: "app.lifecycle")
            breadcrumb.message = "connect 192.0.2.42 token=payload-secret-sentinel"
            breadcrumb.data = ["body": "body-sentinel", "action": "app_initialized"]
            event.breadcrumbs = [breadcrumb]

            let payload = try scrubAndSerialize(event, forbidden: [
                "user-identity-sentinel", "request-sentinel", "server-identity-sentinel", "payload-secret-sentinel",
                "privacy-user-sentinel", "device-identity-sentinel", "geo-identity-sentinel", "body-sentinel", "192.0.2.42"
            ])
            for key in ["user", "request", "server_name"] {
                XCTAssertNil(payload[key], key)
            }
            XCTAssertEqual(payload["tags"] as? [String: String], ["safe_tag": "startup"])
            let contexts = try XCTUnwrap(payload["contexts"] as? [String: Any])
            XCTAssertNil(contexts["geo"])
            XCTAssertEqual(contexts["device"] as? [String: String], ["arch": "arm64"])
            XCTAssertEqual(contexts["runtime"] as? [String: String], ["name": "macOS"])
            let extra = try XCTUnwrap(payload["extra"] as? [String: Any])
            let nested = try XCTUnwrap(extra["nested"] as? [[String: Int]])
            XCTAssertEqual(nested, [["safe_code": 42]])
            let breadcrumbs = try XCTUnwrap(payload["breadcrumbs"] as? [[String: Any]])
            XCTAssertEqual(breadcrumbs.first?["data"] as? [String: String], ["action": "app_initialized"])
        #else
            try skipWithoutSentry()
        #endif
    }

    #if REPOPROMPT_SENTRY_ENABLED
        /// Inspect SDK envelope-item bytes, not merely the scrubber's in-memory properties.
        private func scrubAndSerialize(_ event: Event, forbidden: [String]) throws -> [String: Any] {
            let rawData = try XCTUnwrap(SentryEnvelopeItem(event: event).data)
            let raw = String(decoding: rawData, as: UTF8.self)
            for sentinel in forbidden {
                // Countercheck: bypassing the scrub boundary must expose every fixture sentinel.
                XCTAssertTrue(raw.contains(sentinel), "Fixture did not serialize \(sentinel)")
            }
            let scrubbed = try XCTUnwrap(SentryTelemetryBootstrap.scrubEventForTesting(event))
            let data = try XCTUnwrap(SentryEnvelopeItem(event: scrubbed).data)
            let serialized = String(decoding: data, as: UTF8.self)
            for sentinel in forbidden {
                XCTAssertFalse(serialized.contains(sentinel), "Serialized event leaked \(sentinel)")
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    #else
        private func skipWithoutSentry() throws {
            // A requested Sentry lane must fail rather than silently pass with only skips.
            if ProcessInfo.processInfo.environment["REPOPROMPT_ENABLE_SENTRY"] == "1" {
                XCTFail("Sentry-enabled validation did not compile REPOPROMPT_SENTRY_ENABLED")
                return
            }
            throw XCTSkip("Requires REPOPROMPT_ENABLE_SENTRY=1")
        }
    #endif
}
