#if DEBUG
    import Combine
    import Foundation

    /// Describes access requested by an agent. Constructing this value does not read the file.
    struct PromptLabFilePreparationRequest: Equatable {
        let path: String
        let selection: String?
        let sourceTitle: String?
        let goal: String
        let exampleInputs: String
        let criteria: String
        let target: PromptExperimentResolvedTarget
    }

    enum PromptLabPreparationPayload: Equatable {
        case file(PromptLabFilePreparationRequest)
        case program(PromptLabProgram, PromptLabRunnerKind)

        /// Validate caller-supplied strings only. Even checking file existence or computing
        /// source hashes belongs after the native user authorizes the requested access.
        fileprivate func validateShape() throws {
            switch self {
            case let .file(request):
                guard request.path.hasPrefix("/"), request.path.utf8.count <= 32768,
                      !(request.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                      request.goal.count <= 16000, (request.sourceTitle?.count ?? 0) <= 200,
                      (request.selection?.utf8.count ?? 0) <= 500_000,
                      request.exampleInputs.utf8.count <= 200_000, request.criteria.utf8.count <= 200_000
                else {
                    throw PromptExperimentAuthorityError.invalidRequest("Choose an absolute prompt path, a title up to 200 characters, and a goal of 1–16,000 characters. Preparation examples and criteria must each fit within 200 KB.")
                }
            case let .program(program, runner):
                guard runner == .program || runner == .dspy,
                      program.pythonExecutable.hasPrefix("/"), program.projectRoot.hasPrefix("/"),
                      !program.modulePath.isEmpty, program.modulePath.utf8.count <= 32768,
                      program.pythonExecutable.utf8.count <= 32768, program.projectRoot.utf8.count <= 32768,
                      program.timeoutSeconds.isFinite, (1 ... 900).contains(program.timeoutSeconds),
                      !program.callable.isEmpty, program.callable.utf8.count <= 128,
                      program.environmentKeys.count <= 32,
                      program.environmentKeys.allSatisfy({ $0.utf8.count <= 128 })
                else {
                    throw PromptExperimentAuthorityError.invalidRequest("Choose a program or DSPy runner, an absolute Python interpreter and project folder, a module, and a timeout from 1 to 900 seconds.")
                }
            }
        }
    }

    struct PromptLabPreparationRequest: Identifiable, Equatable {
        enum Status: String {
            case awaitingApproval, running, completed, failed, rejected, cancelled

            var isSettled: Bool {
                self != .awaitingApproval && self != .running
            }
        }

        let id: UUID
        let createdAt: Date
        let payload: PromptLabPreparationPayload
        fileprivate(set) var status: Status = .awaitingApproval
        fileprivate(set) var definition: PromptLabDefinition?
        fileprivate(set) var error: String?

        var title: String {
            switch payload {
            case let .file(request):
                request.sourceTitle ?? URL(fileURLWithPath: request.path).lastPathComponent
            case let .program(program, runner):
                "\(runner == .dspy ? "DSPy" : "Program"): \(URL(fileURLWithPath: program.modulePath).lastPathComponent)"
            }
        }
    }

    /// A one-shot native review gate for agent-requested file access and Python imports.
    /// Permissions are intentionally in memory: restarting the app cannot revive approval.
    /// Native form buttons already express user intent and call preparation methods directly.
    @MainActor
    final class PromptLabPreparationApprovals: ObservableObject {
        typealias Executor = @MainActor (PromptLabPreparationPayload, PromptExperimentService) async throws -> PromptLabDefinition

        @Published private(set) var requests: [PromptLabPreparationRequest] = []
        private let executor: Executor
        private var executions: [UUID: Task<PromptLabDefinition, Error>] = [:]
        private var changeWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
        private let maximumPending = 20
        private let maximumHistory = 50

        init(executor: Executor? = nil) {
            self.executor = executor ?? Self.execute
        }

        func request(id: UUID) -> PromptLabPreparationRequest? {
            requests.first { $0.id == id }
        }

        /// Called by MCP. This queues immutable arguments, with no filesystem or model access.
        @discardableResult
        func submit(_ payload: PromptLabPreparationPayload) throws -> PromptLabPreparationRequest {
            try payload.validateShape()
            guard requests.count(where: { !$0.status.isSettled || executions[$0.id] != nil }) < maximumPending else {
                throw PromptExperimentAuthorityError.invalidRequest("Review or reject pending preparations in Prompt Experiments before requesting more.")
            }
            while requests.count >= maximumHistory,
                  let index = requests.firstIndex(where: { $0.status.isSettled && executions[$0.id] == nil })
            {
                requests.remove(at: index)
            }
            let request = PromptLabPreparationRequest(id: UUID(), createdAt: Date(), payload: payload)
            requests.append(request)
            return request
        }

        /// Native UI only. State changes before suspension, so a second click cannot reuse consent.
        func approve(requestID: UUID, service: PromptExperimentService) async throws {
            let index = try index(of: requestID)
            guard requests[index].status == .awaitingApproval else {
                throw PromptExperimentAuthorityError.invalidRequest("This preparation has already been reviewed. Request a new preparation to run it again.")
            }
            let payload = requests[index].payload
            requests[index].status = .running
            notify(requestID)
            let executor = executor
            let task = Task { @MainActor in
                try Task.checkCancellation()
                return try await executor(payload, service)
            }
            executions[requestID] = task
            do {
                let definition = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                try Task.checkCancellation()
                let current = try self.index(of: requestID)
                guard requests[current].status == .running else {
                    executions[requestID] = nil
                    return
                }
                requests[current].definition = definition
                requests[current].status = .completed
            } catch {
                if let current = requests.firstIndex(where: { $0.id == requestID }), requests[current].status == .running {
                    requests[current].status = error is CancellationError || task.isCancelled ? .cancelled : .failed
                    requests[current].error = requests[current].status == .failed ? error.localizedDescription : nil
                }
            }
            executions[requestID] = nil
            notify(requestID)
        }

        func reject(requestID: UUID) throws {
            let index = try index(of: requestID)
            guard requests[index].status == .awaitingApproval else {
                throw PromptExperimentAuthorityError.invalidRequest("Only a pending preparation can be rejected.")
            }
            requests[index].status = .rejected
            notify(requestID)
        }

        func cancel(requestID: UUID) throws {
            let index = try index(of: requestID)
            guard !requests[index].status.isSettled else { return }
            requests[index].status = .cancelled
            executions[requestID]?.cancel()
            notify(requestID)
        }

        /// Wait for a state change, never grant permission. Terminal requests return immediately.
        func statusOrWait(id: UUID, timeoutSeconds: TimeInterval) async throws -> PromptLabPreparationRequest {
            let index = try index(of: id)
            guard timeoutSeconds.isFinite, (0 ... 3600).contains(timeoutSeconds) else {
                throw PromptExperimentAuthorityError.invalidRequest("The preparation wait must be between 0 and 3600 seconds.")
            }
            try Task.checkCancellation()
            if timeoutSeconds > 0, !requests[index].status.isSettled {
                let waiterID = UUID()
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
                    catch { return }
                    self?.resumeWaiter(requestID: id, waiterID: waiterID)
                }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if Task.isCancelled {
                            continuation.resume()
                        } else {
                            changeWaiters[id, default: [:]][waiterID] = continuation
                        }
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.resumeWaiter(requestID: id, waiterID: waiterID)
                    }
                }
                timeout.cancel()
                try Task.checkCancellation()
            }
            return try requests[self.index(of: id)]
        }

        private func index(of id: UUID) throws -> Int {
            guard let index = requests.firstIndex(where: { $0.id == id }) else {
                throw PromptExperimentAuthorityError.invalidRequest("This preparation is no longer available. Request a new preparation.")
            }
            return index
        }

        private func resumeWaiter(requestID: UUID, waiterID: UUID) {
            let waiter = changeWaiters[requestID]?.removeValue(forKey: waiterID)
            if changeWaiters[requestID]?.isEmpty == true { changeWaiters[requestID] = nil }
            waiter?.resume()
        }

        private func notify(_ id: UUID) {
            let waiters = changeWaiters.removeValue(forKey: id)
            for waiter in waiters?.values ?? [:].values {
                waiter.resume()
            }
        }

        private static func execute(_ payload: PromptLabPreparationPayload, service: PromptExperimentService) async throws -> PromptLabDefinition {
            switch payload {
            case let .file(request):
                var source = try PromptLabSource.importFile(url: URL(fileURLWithPath: request.path), selection: request.selection)
                if let title = request.sourceTitle { source.title = title }
                return try await service.prepareDefinition(
                    source: source, goal: request.goal, exampleInputs: request.exampleInputs,
                    criteria: request.criteria, targetSelector: request.target.selector, expectedTarget: request.target
                )
            case let .program(program, runner):
                return try await service.describeProgram(program, runner: runner)
            }
        }
    }
#endif
