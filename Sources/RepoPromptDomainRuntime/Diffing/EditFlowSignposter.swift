#if DEBUG || EDIT_FLOW_PERF
    #if canImport(os)
        import os

        typealias EditFlowSignposter = OSSignposter
        typealias EditFlowSignpostIntervalState = OSSignpostIntervalState
    #else
        import Logging

        typealias EditFlowSignpostIntervalState = ContinuousClock.Instant

        struct EditFlowSignposter {
            private let logger: Logger

            init(subsystem: String, category: String) {
                logger = Logger(label: "\(subsystem).\(category)")
            }

            func beginInterval(_ name: StaticString) -> EditFlowSignpostIntervalState {
                logger.debug("begin \(name)")
                return ContinuousClock.now
            }

            func endInterval(_ name: StaticString, _ state: EditFlowSignpostIntervalState) {
                logger.debug("end \(name) duration=\(state.duration(to: .now))")
            }

            func emitEvent(_ name: StaticString) {
                logger.debug("event \(name)")
            }
        }
    #endif
#endif
