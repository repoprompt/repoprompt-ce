import Foundation

#if DEBUG
    enum CodeMapRuntimeDiagnostics {
        static func start() -> Double? {
            ProcessInfo.processInfo.systemUptime * 1000
        }

        static func cacheRebuild(rootCount _: Int, requestCount _: Int, startMS _: Double?) {}
        static func cacheCheck(requestCount _: Int, queueableRequests _: Int, droppedRequests _: Int, startMS _: Double?) {}
        static func prune(rootCount _: Int, startMS _: Double?) {}
        static func enqueue(queueableRequests _: Int, startMS _: Double?) {}
    }
#endif
