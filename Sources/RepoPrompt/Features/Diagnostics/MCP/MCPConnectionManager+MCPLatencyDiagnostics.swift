// MARK: - Optimized MCP latency diagnostic surface

import CryptoKit
import Foundation
import MCP
import RepoPromptShared

#if MCP_LATENCY_DIAGNOSTICS && !DEBUG
    extension ServerNetworkManager {
        enum MCPLatencyDiagnosticOperation: String, CaseIterable {
            case serverIdentity = "mcp_latency_server_identity"
            case captureBegin = "mcp_read_search_capture_begin"
            case captureSnapshot = "mcp_read_search_capture_snapshot"
        }

        private static let mcpLatencyDiagnosticsToolName = "__repoprompt_debug_diagnostics"

        nonisolated static func isMCPLatencyDiagnosticsToolName(_ toolName: String) -> Bool {
            toolName == mcpLatencyDiagnosticsToolName
        }

        func handleMCPLatencyDiagnosticsTool(arguments: [String: Value]) -> CallTool.Result {
            guard let rawOperation = arguments["op"]?.stringValue,
                  let operation = MCPLatencyDiagnosticOperation(rawValue: rawOperation)
            else {
                return mcpLatencyDiagnosticsError(
                    code: "unknown_op",
                    message: "Only bounded MCP latency identity and capture operations are available in this optimized diagnostic build."
                )
            }

            switch operation {
            case .serverIdentity:
                return mcpLatencyDiagnosticsResult(Self.mcpLatencyServerIdentityPayload())
            case .captureBegin:
                return mcpLatencyCaptureBegin(arguments: arguments)
            case .captureSnapshot:
                return mcpLatencyCaptureSnapshot(arguments: arguments)
            }
        }

        private func mcpLatencyCaptureBegin(arguments: [String: Value]) -> CallTool.Result {
            guard let rawLabel = arguments["label"]?.stringValue else {
                return mcpLatencyDiagnosticsError(code: "invalid_params", message: "Missing required string argument `label`.")
            }
            let label = String(rawLabel.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }.prefix(96))
            guard !label.isEmpty else {
                return mcpLatencyDiagnosticsError(code: "invalid_params", message: "`label` must contain an alphanumeric character.")
            }
            let maxSamples = arguments["max_samples"]?.intValue ?? 20000
            guard (100 ... 100_000).contains(maxSamples) else {
                return mcpLatencyDiagnosticsError(code: "invalid_params", message: "`max_samples` must be an integer between 100 and 100000.")
            }

            switch EditFlowPerf.beginDebugCapture(
                label: label,
                maxSamples: maxSamples,
                mode: .mcpLatencyEvidence
            ) {
            case let .started(snapshot):
                MCPResponseDeliveryTracer.resetDebugEvents()
                return mcpLatencyDiagnosticsResult([
                    "ok": true,
                    "op": MCPLatencyDiagnosticOperation.captureBegin.rawValue,
                    "capture": snapshot.payload()
                ])
            case let .busy(snapshot):
                return mcpLatencyDiagnosticsError(
                    code: "capture_busy",
                    message: "An MCP latency capture is already active with label `\(snapshot.label)`."
                )
            }
        }

        private func mcpLatencyCaptureSnapshot(arguments: [String: Value]) -> CallTool.Result {
            let finish = arguments["finish"]?.boolValue ?? true
            let includeTimeline = arguments["include_timeline"]?.boolValue ?? true
            let capture = EditFlowPerf.debugCaptureSnapshot(finish: finish)
            let delivery = MCPResponseDeliveryTracer.debugCaptureSnapshot(finish: finish)
            return mcpLatencyDiagnosticsResult([
                "ok": true,
                "op": MCPLatencyDiagnosticOperation.captureSnapshot.rawValue,
                "capture": capture.payload(includeTimeline: includeTimeline),
                "delivery_events": delivery.events.map(\.payload),
                "delivery_dropped_event_count": delivery.droppedEventCount
            ])
        }

        private nonisolated static func mcpLatencyServerIdentityPayload() -> [String: Any] {
            let bundle = Bundle.main
            let executableURL = bundle.executableURL?.standardizedFileURL
            let executableData = executableURL.flatMap { try? Data(contentsOf: $0, options: [.mappedIfSafe]) }
            let executableSHA256 = executableData.map { SHA256.hash(data: $0).hexString }
            let helperURL = bundle.bundleURL
                .appendingPathComponent("Contents/MacOS/repoprompt-mcp")
                .standardizedFileURL
            let helperData = try? Data(contentsOf: helperURL, options: [.mappedIfSafe])
            let provenanceURL = bundle.url(
                forResource: "RepoPromptMCPLatencyDiagnosticProvenance",
                withExtension: "json"
            )
            let provenanceData = provenanceURL.flatMap { try? Data(contentsOf: $0) }
            let provenance = provenanceData.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let helperSHA256 = helperData.map { SHA256.hash(data: $0).hexString }
            let provenanceSHA256 = provenanceData.map { SHA256.hash(data: $0).hexString }
            let identity: [String: Any] = [
                "identity_authority": "server_process",
                "app_configuration": "optimized_diagnostic",
                "swift_configuration": "release",
                "diagnostic_surface": "mcp_latency_v1",
                "ordinary_release_artifact": false,
                "process_identifier": ProcessInfo.processInfo.processIdentifier,
                "bundle_path": bundle.bundleURL.standardizedFileURL.path,
                "executable_path": executableURL?.path ?? NSNull(),
                "executable_sha256": executableSHA256 ?? NSNull(),
                "embedded_cli_path": helperURL.path,
                "embedded_cli_sha256": helperSHA256 ?? NSNull(),
                "bundle_identifier": bundle.bundleIdentifier ?? NSNull(),
                "signing_mode": bundle.object(forInfoDictionaryKey: "RepoPromptSigningMode") ?? NSNull(),
                "secure_storage_backend": bundle.object(forInfoDictionaryKey: "RepoPromptDebugSecureStorageBackend") ?? NSNull(),
                "marketing_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? NSNull(),
                "build_number": bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? NSNull(),
                "provenance": provenance ?? NSNull(),
                "provenance_sha256": provenanceSHA256 ?? NSNull()
            ]
            return [
                "ok": true,
                "op": MCPLatencyDiagnosticOperation.serverIdentity.rawValue,
                "server_app_identity": identity
            ]
        }

        private nonisolated func mcpLatencyDiagnosticsResult(
            _ object: [String: Any],
            isError: Bool = false
        ) -> CallTool.Result {
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}"
            return CallTool.Result(
                content: [MCP.Tool.Content.text(text: text, annotations: nil, _meta: nil)],
                isError: isError
            )
        }

        private nonisolated func mcpLatencyDiagnosticsError(
            code: String,
            message: String
        ) -> CallTool.Result {
            mcpLatencyDiagnosticsResult([
                "ok": false,
                "code": code,
                "error": message
            ], isError: true)
        }
    }

    private extension SHA256.Digest {
        var hexString: String {
            map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
