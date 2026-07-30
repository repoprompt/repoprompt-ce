@testable import RepoPromptApp
import XCTest

#if REPOPROMPT_SENTRY_ENABLED
    @_spi(Private) import Sentry
#endif

final class SentryTelemetryPrivacyTests: XCTestCase {
    func testSerializedEventScrubsTypedStacktracesMechanismsDebugImagesAndDist() throws {
        #if REPOPROMPT_SENTRY_ENABLED
            let event = makeTypedEvent(level: .error, mechanismType: "NSError")
            let payload = try scrubAndSerialize(event)

            assertSensitiveFixtureIsAbsent(payload.eventJSON, envelopeData: payload.envelopeData)
            XCTAssertNil(payload.eventJSON["dist"])
            XCTAssertTrue(payload.envelopeString.contains("DEBUG-ID-ALICE"))
            XCTAssertTrue(payload.envelopeString.contains("0x0000000100000000"))
            let eventStrings = stringValues(in: payload.eventJSON)
            XCTAssertTrue(eventStrings.contains("/System/Library/Frameworks/AppKit.framework/AppKit"))
            XCTAssertFalse(eventStrings.contains { $0.contains("private-plugin.bundle") })
        #else
            throw XCTSkip("Requires REPOPROMPT_ENABLE_SENTRY=1")
        #endif
    }

    func testSerializedCrashShapedEventRemovesPathsAndPreservesSymbolication() throws {
        #if REPOPROMPT_SENTRY_ENABLED
            let event = makeTypedEvent(level: .fatal, mechanismType: "signal")
            event.exceptions?.first?.mechanism?.handled = false
            let payload = try scrubAndSerialize(event)

            assertSensitiveFixtureIsAbsent(payload.eventJSON, envelopeData: payload.envelopeData)
            XCTAssertNil(payload.eventJSON["dist"])
            XCTAssertTrue(payload.envelopeString.contains("DEBUG-ID-ALICE"))
            XCTAssertTrue(payload.envelopeString.contains("0x0000000100001234"))
        #else
            throw XCTSkip("Requires REPOPROMPT_ENABLE_SENTRY=1")
        #endif
    }

    func testSerializedHangShapedEventRemovesPathsAndPreservesSymbolication() throws {
        #if REPOPROMPT_SENTRY_ENABLED
            let event = makeTypedEvent(level: .error, mechanismType: "AppHang")
            event.exceptions?.first?.type = "AppHangNonFullyBlocking"
            event.exceptions?.first?.value = "App hanging while reading /Users/alice/customer-project"
            event.exceptions?.first?.stacktrace?.snapshot = true
            let payload = try scrubAndSerialize(event)

            assertSensitiveFixtureIsAbsent(payload.eventJSON, envelopeData: payload.envelopeData)
            XCTAssertNil(payload.eventJSON["dist"])
            XCTAssertTrue(payload.envelopeString.contains("DEBUG-ID-ALICE"))
            XCTAssertTrue(payload.envelopeString.contains("AppHang"))
        #else
            throw XCTSkip("Requires REPOPROMPT_ENABLE_SENTRY=1")
        #endif
    }
}

#if REPOPROMPT_SENTRY_ENABLED
    private extension SentryTelemetryPrivacyTests {
        struct SerializedPayload {
            let eventJSON: [String: Any]
            let envelopeData: Data
            let envelopeString: String
        }

        func makeTypedEvent(level: SentryLevel, mechanismType: String) -> Event {
            let sensitiveFrame = Frame()
            sensitiveFrame.fileName = "/Users/alice/customer-project/PrivateSource.swift"
            sensitiveFrame.package = "/Users/alice/Library/Application Support/private-plugin.bundle"
            sensitiveFrame.function = "load token=fixture-secret"
            sensitiveFrame.module = "customer module /Users/alice/customer-project"
            sensitiveFrame.instructionAddress = "0x0000000100001234"
            sensitiveFrame.imageAddress = "0x0000000100000000"
            sensitiveFrame.contextLine = "let token = fixture-secret // /Users/alice/customer-project"
            sensitiveFrame.preContext = ["authorization: Bearer fixture-secret"]
            sensitiveFrame.postContext = ["connect 192.168.1.42"]
            sensitiveFrame.vars = [
                "workspace": "/Users/alice/customer-project",
                "authorization": "Bearer fixture-secret"
            ]

            let systemFrame = Frame()
            systemFrame.package = "/System/Library/Frameworks/AppKit.framework/AppKit"
            systemFrame.function = "NSApplicationMain"
            systemFrame.instructionAddress = "0x0000000180001234"
            systemFrame.imageAddress = "0x0000000180000000"

            let stacktrace = SentryStacktrace(
                frames: [sensitiveFrame, systemFrame],
                registers: [
                    "pc": "0x0000000100001234",
                    "note": "/Users/alice/customer-project token=fixture-secret"
                ]
            )

            let thread = SentryThread(threadId: NSNumber(value: 1))
            thread.name = "worker /Users/alice/customer-project"
            thread.current = true
            thread.crashed = level == .fatal ? true : nil
            thread.stacktrace = stacktrace

            let exception = Exception(
                value: "failure at /Users/alice/customer-project",
                type: "PrivateError token=fixture-secret"
            )
            exception.module = "/Users/alice/customer-project/PrivateModule"
            exception.stacktrace = stacktrace

            let mechanism = Mechanism(type: mechanismType)
            mechanism.desc = "authorization: Bearer fixture-secret at /Users/alice/customer-project"
            mechanism.helpLink = "file:///Users/alice/customer-project/private-help.html"
            mechanism.data = [
                "workspace": "/Users/alice/customer-project",
                "password": "fixture-secret",
                "safe_code": 42
            ]
            let mechanismContext = MechanismContext()
            mechanismContext.signal = [
                "name": "SIGABRT",
                "detail": "/Users/alice/customer-project"
            ]
            mechanismContext.machException = [
                "name": "EXC_CRASH",
                "detail": "token=fixture-secret"
            ]
            mechanism.meta = mechanismContext
            exception.mechanism = mechanism

            let debugMeta = DebugMeta()
            debugMeta.debugID = "DEBUG-ID-ALICE"
            debugMeta.type = "macho"
            debugMeta.imageAddress = "0x0000000100000000"
            debugMeta.imageVmAddress = "0x0000000100000000"
            debugMeta.imageSize = NSNumber(value: 4096)
            debugMeta.codeFile = "/Users/alice/Library/Application Support/private-plugin.bundle"

            let event = Event(level: level)
            event.dist = "restored-build-number"
            event.stacktrace = stacktrace
            event.threads = [thread]
            event.exceptions = [exception]
            event.debugMeta = [debugMeta]
            event.extra = [
                "workspace": "/Users/alice/customer-project",
                "token": "fixture-secret"
            ]
            return event
        }

        func scrubAndSerialize(_ event: Event) throws -> SerializedPayload {
            let scrubbed = try XCTUnwrap(SentryTelemetryBootstrap.scrubEventForTesting(event))
            let eventJSON = scrubbed.serialize()
            _ = try JSONSerialization.data(withJSONObject: eventJSON)

            let item = SentryEnvelopeItem(event: scrubbed)
            let envelope = SentryEnvelope(id: scrubbed.eventId, items: [item])
            let envelopeData = try XCTUnwrap(SentrySerializationSwift.data(with: envelope))
            let envelopeString = try XCTUnwrap(String(data: envelopeData, encoding: .utf8))
            return SerializedPayload(
                eventJSON: eventJSON,
                envelopeData: envelopeData,
                envelopeString: envelopeString
            )
        }

        func assertSensitiveFixtureIsAbsent(
            _ eventJSON: [String: Any],
            envelopeData: Data,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let serialized = String(decoding: envelopeData, as: UTF8.self)
            let eventStrings = stringValues(in: eventJSON)
            XCTAssertFalse(
                eventStrings.contains { $0.contains("/Users/alice") },
                file: file,
                line: line
            )
            for forbiddenPath in ["/Users/alice", #"\/Users\/alice"#] {
                XCTAssertFalse(serialized.contains(forbiddenPath), forbiddenPath, file: file, line: line)
            }
            for forbidden in [
                "fixture-secret",
                "192.168.1.42",
                "restored-build-number"
            ] {
                XCTAssertFalse(serialized.contains(forbidden), forbidden, file: file, line: line)
            }
            XCTAssertFalse(containsKey("dist", in: eventJSON), file: file, line: line)
        }

        func stringValues(in value: Any) -> [String] {
            if let string = value as? String {
                return [string]
            }
            if let dictionary = value as? [String: Any] {
                return dictionary.values.flatMap { stringValues(in: $0) }
            }
            if let array = value as? [Any] {
                return array.flatMap { stringValues(in: $0) }
            }
            return []
        }

        func containsKey(_ key: String, in value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary.keys.contains(key) ||
                    dictionary.values.contains { containsKey(key, in: $0) }
            }
            if let array = value as? [Any] {
                return array.contains { containsKey(key, in: $0) }
            }
            return false
        }
    }
#endif
