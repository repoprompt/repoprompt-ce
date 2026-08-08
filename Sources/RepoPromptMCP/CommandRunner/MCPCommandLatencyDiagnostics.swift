import Darwin
import Foundation
import MCP

#if DEBUG || MCP_LATENCY_TRACE
    /// Opt-in client-side C0-C2 recorder for MCP latency diagnostics.
    ///
    /// DEBUG builds include this recorder for local diagnostics. Optimized diagnostic
    /// builds must opt in with `RPCE_ENABLE_MCP_LATENCY_TRACE=1`; ordinary release
    /// builds do not compile it. Trace records exclude arguments and returned content.
    actor MCPCommandLatencyDiagnostics {
        enum Outcome: String {
            case success
            case toolError = "tool_error"
            case clientError = "client_error"
            case cancelled
            case timeout
            case transportClosed = "transport_closed"
        }

        enum OutputFormat: String {
            case formatted
            case raw
        }

        struct Invocation {
            let id: UUID
            let toolName: String
            let outputFormat: OutputFormat
            let c0Nanoseconds: UInt64
        }

        static let shared = MCPCommandLatencyDiagnostics()
        static let environmentKey = "RP_MCP_LATENCY_TRACE_PATH"
        static let requestIdentityArgument = "_latencyTraceID"

        static func prepareInvocation(
            toolName: String,
            arguments: [String: Value]?
        ) -> (invocation: Invocation, arguments: [String: Value]?) {
            let configured = configuredTracePath() != nil
            let suppliedID = arguments?[requestIdentityArgument]?.stringValue.flatMap(UUID.init(uuidString:))
            let invocation = Invocation(
                id: suppliedID ?? UUID(),
                toolName: toolName,
                outputFormat: wantsRawJSON(arguments?["_rawJSON"]) ? .raw : .formatted,
                c0Nanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            guard configured else { return (invocation, arguments) }
            var tracedArguments = arguments ?? [:]
            tracedArguments[requestIdentityArgument] = .string(invocation.id.uuidString)
            return (invocation, tracedArguments)
        }

        static func outcome(for error: Error) -> Outcome {
            if error is CancellationError || Task.isCancelled {
                return .cancelled
            }
            if let error = error as? InteractiveSessionError {
                switch error {
                case .cancelled:
                    return .cancelled
                case .bootstrapResponseTimeout, .toolCallTimeout:
                    return .timeout
                case .notConnected, .connectionReset, .serverClosed, .writeFailed, .pollFailed:
                    return .transportClosed
                case .socketCreationFailed, .descriptorConfigurationFailed, .pathTooLong,
                     .connectFailed, .appNotRunning, .approvalDenied, .handshakeFailed:
                    return .clientError
                }
            }
            if let error = error as? MCPError {
                switch error {
                case .connectionClosed, .transportError:
                    return .transportClosed
                case .parseError, .invalidRequest, .methodNotFound, .invalidParams,
                     .internalError, .serverError, .urlElicitationRequired:
                    return .clientError
                }
            }
            return .clientError
        }

        private var descriptor: Int32?
        private var attemptedOpen = false

        func record(
            invocation: Invocation,
            c1Nanoseconds: UInt64,
            c2Nanoseconds: UInt64,
            result: CallTool.Result?,
            outcome: Outcome
        ) {
            guard let descriptor = traceDescriptor() else { return }
            let contentBlockCount = result?.content.count ?? 0
            let textContentBlockCount = result?.content.count(where: { content in
                if case .text = content { return true }
                return false
            }) ?? 0
            let returnedTextBytes = result?.content.reduce(into: 0) { total, content in
                if case let .text(text, _, _) = content {
                    total += text.utf8.count
                }
            } ?? 0
            let c1 = max(invocation.c0Nanoseconds, c1Nanoseconds)
            let c2 = max(c1, c2Nanoseconds)
            let payload: [String: Any] = [
                "schema_version": 1,
                "diagnostic_configuration": diagnosticConfiguration,
                "invocation_id": invocation.id.uuidString,
                "tool_name": sanitizedToolName(invocation.toolName),
                "output_format": invocation.outputFormat.rawValue,
                "c0_ns": invocation.c0Nanoseconds,
                "c1_ns": c1,
                "c2_ns": c2,
                "call_duration_ms": milliseconds(from: invocation.c0Nanoseconds, to: c1),
                "print_duration_ms": milliseconds(from: c1, to: c2),
                "content_block_count": contentBlockCount,
                "text_content_block_count": textContentBlockCount,
                "returned_text_bytes": returnedTextBytes,
                "is_error": result?.isError == true,
                "outcome": outcome.rawValue
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            ) else { return }
            var line = data
            line.append(0x0A)
            line.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }

        private static func wantsRawJSON(_ value: Value?) -> Bool {
            guard let value else { return false }
            switch value {
            case let .bool(flag):
                return flag
            case let .int(number):
                return number != 0
            case let .double(number):
                return number != 0
            case let .string(raw):
                return ["1", "true", "yes", "y", "on"].contains(
                    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            default:
                return false
            }
        }

        private static func configuredTracePath() -> String? {
            guard let path = ProcessInfo.processInfo.environment[environmentKey],
                  path.hasPrefix("/"),
                  !path.contains("\u{0}")
            else { return nil }
            return path
        }

        private var diagnosticConfiguration: String {
            #if DEBUG
                "debug"
            #else
                "optimized_diagnostic"
            #endif
        }

        private func traceDescriptor() -> Int32? {
            if attemptedOpen { return descriptor }
            attemptedOpen = true
            guard let path = Self.configuredTracePath() else { return nil }

            let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            let fd = Darwin.open(path, flags, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return nil }
            guard Darwin.fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
                Darwin.close(fd)
                return nil
            }
            descriptor = fd
            return fd
        }

        private func sanitizedToolName(_ raw: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let scalars = raw.unicodeScalars.prefix(80).map { scalar in
                allowed.contains(scalar) ? Character(String(scalar)) : "_"
            }
            let value = String(scalars)
            return value.isEmpty ? "unknown" : value
        }

        private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
            Double(end - start) / 1_000_000
        }
    }
#endif
