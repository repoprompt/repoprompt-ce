import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared

package extension PromptExportExecutionEnvelope {
    static func capture(isPromptExport: Bool, state: MCPToolCallDeadlineEnvelopeState, executionWatchdogEnvironment: MCPToolExecutionWatchdogEnvironment, wallClockNow: @Sendable () -> Date = { Date() }) -> Self? {
        guard isPromptExport else { return nil }
        let receiptInstant = executionWatchdogEnvironment.now()
        let totalEnvelopeSeconds = TimeInterval(MCPTimeoutPolicy.promptExportTotalEnvelopeSeconds)
        let remainingSeconds: TimeInterval
        let cancellationOrigin: MCPToolExecutionCancellationOrigin
        switch state {
        case let .valid(suppliedEnvelope):
            switch suppliedEnvelope.timeoutMode {
            case .ordinaryDefault:
                guard let expiresAtUnixMilliseconds = suppliedEnvelope.expiresAtUnixMilliseconds else {
                    return nil
                }
                let wallNowMilliseconds = Int64((wallClockNow().timeIntervalSince1970 * 1000).rounded(.down))
                let suppliedRemaining = (
                    TimeInterval(expiresAtUnixMilliseconds)
                        - TimeInterval(wallNowMilliseconds)
                ) / 1000
                remainingSeconds = min(totalEnvelopeSeconds, max(0, suppliedRemaining))
                cancellationOrigin = .clientDeadline
            case .explicitFinite, .explicitUnbounded:
                return nil
            }
        case .absent:
            remainingSeconds = totalEnvelopeSeconds
            cancellationOrigin = .serverExportEnvelope
        case .invalid:
            return nil
        }
        let outerDeadline = receiptInstant + .seconds(remainingSeconds)
        return PromptExportExecutionEnvelope(
            admissionDeadline: MCPDomainAdmissionDeadline(
                instant: outerDeadline - .seconds(MCPTimeoutPolicy.promptExportReservedProviderAndCleanupSeconds),
                now: executionWatchdogEnvironment.now,
                sleep: executionWatchdogEnvironment.sleep
            ),
            cleanupNotAfter: outerDeadline - .seconds(
                MCPTimeoutPolicy.promptExportResponseDeliveryAllowanceSeconds
            ),
            responseDeliveryDeadline: MCPExportResponseDeliveryDeadlineRegistry.Deadline(
                instant: outerDeadline,
                now: executionWatchdogEnvironment.now
            ),
            cancellationOrigin: cancellationOrigin
        )
    }
}
