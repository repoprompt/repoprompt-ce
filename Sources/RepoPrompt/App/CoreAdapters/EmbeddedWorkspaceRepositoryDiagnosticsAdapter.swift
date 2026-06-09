import Foundation
import RepoPromptCore

final class EmbeddedWorkspaceRepositoryDiagnosticsAdapter: WorkspaceRepositoryDiagnosticsSink, @unchecked Sendable {
    #if DEBUG
        private enum OperationKind: String {
            case flush
            case write
        }

        private struct OperationKey: Hashable {
            let kind: OperationKind
            let urlID: String
            let sequence: String
        }

        private let lock = NSLock()
        private var enqueueCorrelations: [OperationKey: EditFlowPerf.LifecycleCorrelation] = [:]
        private var activeCorrelations: [OperationKey: EditFlowPerf.LifecycleCorrelation] = [:]
        private var activeIntervals: [OperationKey: EditFlowPerf.IntervalState] = [:]
    #endif

    func record(_ diagnostic: WorkspaceRepositoryDiagnostic) {
        #if DEBUG
            switch diagnostic {
            case let .warning(code, message):
                WorkspaceRestorePerfLog.event("workspaceRepository.warning", fields: ["code": code, "message": message])
            case let .recovery(code, message):
                WorkspaceRestorePerfLog.event("workspaceRepository.recovery", fields: ["code": code, "message": message])
            case let .event(name, fields):
                recordEditFlowEvent(name: name, fields: fields)
                WorkspaceRestorePerfLog.event(name, fields: fields)
            }
        #endif
    }

    #if DEBUG
        private func recordEditFlowEvent(name: String, fields: [String: String]) {
            guard let urlID = fields["urlID"], let sequence = fields["sequence"] else { return }

            switch name {
            case "workspaceSave.enqueue":
                guard let correlation = EditFlowPerf.currentLifecycleCorrelation else { return }
                lock.lock()
                enqueueCorrelations[OperationKey(kind: .write, urlID: urlID, sequence: sequence)] = correlation
                lock.unlock()

            case "workspaceSave.flush.begin":
                begin(
                    key: OperationKey(kind: .flush, urlID: urlID, sequence: sequence),
                    stage: EditFlowPerf.Stage.WorkspaceDurability.flushWait,
                    lifecycle: EditFlowPerf.Lifecycle.WorkspaceDurability.flushBegan,
                    correlation: EditFlowPerf.currentLifecycleCorrelation
                )

            case "workspaceSave.flush.end":
                end(
                    key: OperationKey(kind: .flush, urlID: urlID, sequence: sequence),
                    stage: EditFlowPerf.Stage.WorkspaceDurability.flushWait,
                    lifecycle: EditFlowPerf.Lifecycle.WorkspaceDurability.flushEnded
                )

            case "workspaceSave.write.begin":
                let key = OperationKey(kind: .write, urlID: urlID, sequence: sequence)
                lock.lock()
                let correlation = enqueueCorrelations[key]
                lock.unlock()
                begin(
                    key: key,
                    stage: EditFlowPerf.Stage.WorkspaceDurability.atomicWrite,
                    lifecycle: EditFlowPerf.Lifecycle.WorkspaceDurability.writeBegan,
                    correlation: correlation
                )

            case "workspaceSave.write.end":
                end(
                    key: OperationKey(kind: .write, urlID: urlID, sequence: sequence),
                    stage: EditFlowPerf.Stage.WorkspaceDurability.atomicWrite,
                    lifecycle: EditFlowPerf.Lifecycle.WorkspaceDurability.writeEnded
                )

            default:
                break
            }
        }

        private func begin(
            key: OperationKey,
            stage: StaticString,
            lifecycle: StaticString,
            correlation: EditFlowPerf.LifecycleCorrelation?
        ) {
            let interval = EditFlowPerf.begin(stage)
            EditFlowPerf.lifecycleEvent(lifecycle, correlation: correlation)
            lock.lock()
            if let correlation { activeCorrelations[key] = correlation }
            if let interval { activeIntervals[key] = interval }
            lock.unlock()
        }

        private func end(key: OperationKey, stage: StaticString, lifecycle: StaticString) {
            lock.lock()
            let correlation = activeCorrelations.removeValue(forKey: key)
            let interval = activeIntervals.removeValue(forKey: key)
            enqueueCorrelations.removeValue(forKey: key)
            lock.unlock()
            EditFlowPerf.lifecycleEvent(lifecycle, correlation: correlation)
            EditFlowPerf.end(stage, interval)
        }
    #endif
}
