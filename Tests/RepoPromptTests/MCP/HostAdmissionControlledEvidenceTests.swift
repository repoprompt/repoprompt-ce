import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
@testable import RepoPromptWorkspaceContext
import XCTest

#if DEBUG
    /// Opt-in diagnostics: identical source is compiled against main and the candidate.
    /// Run through conductor with .build/host-ab/config.json; ordinary CI skips it.
    @MainActor
    final class HostAdmissionControlledEvidenceTests: XCTestCase {
        func testControlledAB() async throws {
            if let workload = ProcessInfo.processInfo.environment["HOST_AB_CHILD"] {
                _ = try WorkspaceTestProcessSandbox.validate()
                try await measure(workload.split(separator: ",").map(String.init))
                return
            }
            let configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/host-ab/config.json")
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                throw XCTSkip("Opt-in controlled performance diagnostic")
            }
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
            // Consume the opt-in so a later ordinary test run cannot repeat the benchmark.
            try FileManager.default.moveItem(at: configURL, to: configURL.deletingLastPathComponent().appendingPathComponent("consumed-\(UUID().uuidString).json"))
            if let pilot = config?["pilot_workload"] as? String {
                _ = try WorkspaceTestProcessSandbox.validate()
                try await measure([pilot])
                return
            }
            let bundles = try XCTUnwrap(config?["bundles"] as? [String: String])
            let xctest = try XCTUnwrap(config?["xctest"] as? String)
            let output = try URL(fileURLWithPath: XCTUnwrap(config?["output"] as? String))
            let repetitions = try XCTUnwrap(config?["repetitions"] as? Int)
            guard repetitions >= 10 else { throw CocoaError(.validationMissingMandatoryProperty) }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Interleaved, counterbalanced AB/BA pairs. One fresh process per
            // variant/repetition runs the same ordered cases on one loaded repository.
            let workloads = config?["workloads"] as? [String] ?? ["mixed", "search", "read"]
            for repetition in 0 ..< repetitions {
                for variant in repetition.isMultiple(of: 2) ? ["base", "branch"] : ["branch", "base"] {
                    let sandbox = output.appendingPathComponent("\(repetition)-\(variant)")
                    var environment = ProcessInfo.processInfo.environment
                    for directory in ["home", "tmp", "config", "cache", "data"] {
                        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent(directory), withIntermediateDirectories: true)
                    }
                    try Data().write(to: sandbox.appendingPathComponent(".issue944-test-sandbox"))
                    environment["REPOPROMPT_TEST_SANDBOX_ROOT"] = sandbox.path
                    for (key, suffix) in [
                        ("HOME", "home"), ("CFFIXED_USER_HOME", "home"), ("TMPDIR", "tmp"), ("TMP", "tmp"),
                        ("TEMP", "tmp"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data")
                    ] {
                        environment[key] = sandbox.appendingPathComponent(suffix).path
                    }
                    environment["HOST_AB_CHILD"] = workloads.joined(separator: ",")
                    environment["HOST_AB_VARIANT"] = variant
                    environment["HOST_AB_REPETITION"] = String(repetition)
                    let log = sandbox.appendingPathComponent("sample.log")
                    FileManager.default.createFile(atPath: log.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: log)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: xctest)
                    process.arguments = try ["-XCTest", "RepoPromptTests.HostAdmissionControlledEvidenceTests/testControlledAB", XCTUnwrap(bundles[variant])]
                    // The runner's framework path is shared toolchain state. Never
                    // inherit injected libraries that could mix candidate/base images.
                    environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
                    environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
                    environment.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH")
                    process.environment = environment
                    process.standardOutput = handle
                    process.standardError = handle
                    try process.run()
                    let timeout = DispatchWorkItem {
                        guard process.isRunning else { return }
                        process.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
                    process.waitUntilExit()
                    timeout.cancel()
                    try handle.close()
                    let transcript = try String(contentsOf: log, encoding: .utf8)
                    let evidence = transcript.split(separator: "\n").filter { $0.hasPrefix("HOST_AB_SAMPLE ") }
                    print(evidence.joined(separator: "\n"))
                    guard process.terminationStatus == 0, evidence.count == workloads.count else {
                        XCTFail("Invalid sample \(log.path): exit=\(process.terminationStatus)\n\(transcript.suffix(6000))")
                        return
                    }
                }
            }
        }

        private func measure(_ workloads: [String]) async throws {
            // Fail at the actual composition error rather than allowing root setup to
            // swallow it into three transient retries (e.g. an aliased test HOME).
            let runtime = try CodeMapArtifactRuntime.processWide()
            _ = try runtime.bindingEngine()
            try await MCPSharedServerTestLease.shared.withLease { ownership in
                let fixture = try await PersistentMCPTestFixture.make(lease: ownership)
                let context = fixture.contextA
                do {
                    await context.window.workspaceFileContextStore.unloadRoot(id: context.rootID)
                    let payload = String(repeating: "// needle = 123456789 controlled search corpus text\n", count: 160)
                    let source = context.rootURL.appendingPathComponent("Sources")
                    var searchBytes = 0
                    for index in 0 ..< 2048 {
                        searchBytes += payload.utf8.count
                        try payload.write(to: source.appendingPathComponent("Corpus\(index).txt"), atomically: false, encoding: .utf8)
                    }
                    // Separate content-search scale from initial full-repository CodeMap
                    // construction. Structure requests still use real parsed Swift APIs.
                    for index in 0 ..< 24 {
                        try "public struct Benchmark_\(index) { public func benchmark_\(index)() {} }\n".write(
                            to: source.appendingPathComponent("File\(index).swift"), atomically: false, encoding: .utf8
                        )
                    }
                    let largeText = String(repeating: "host capacity evidence line\n", count: 8192)
                    for index in 0 ..< 24 {
                        try largeText.write(to: source.appendingPathComponent("Read\(index).txt"), atomically: false, encoding: .utf8)
                    }
                    try Self.git(["init", "-q", context.rootURL.path])
                    try Self.git(["-C", context.rootURL.path, "add", "Sources"])
                    try Self.git([
                        "-C",
                        context.rootURL.path,
                        "-c",
                        "user.name=Benchmark",
                        "-c",
                        "user.email=benchmark@example.invalid",
                        "-c",
                        "commit.gpgsign=false",
                        "-c",
                        "core.hooksPath=/dev/null",
                        "commit",
                        "-qm",
                        "fixture"
                    ])
                    try "git status evidence\n".write(to: context.rootURL.appendingPathComponent("git-probe.txt"), atomically: false, encoding: .utf8)
                    _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: context.window, path: context.rootURL.path)
                    let workspace = try XCTUnwrap(context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID })
                    await context.window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "HostAdmissionControlledEvidence")
                    context.window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                    try await fixture.registerDomainWorkspace(context)
                    let endpoint = try fixture.endpointA()
                    let bind = try await endpoint.callTool(name: "bind_context", arguments: ["op": "bind", "context_id": context.tabID.uuidString])
                    try Self.check(bind.rawJSON, contains: nil)
                    // A committed repository is required for the production graph's Git
                    // identity. Wait on real observable indexing/writer quiescence, not a
                    // fixed sleep or test override. Report this setup cost separately.
                    let settleStart = DispatchTime.now().uptimeNanoseconds
                    try await Self.quiesce(context.window.workspaceFileContextStore)
                    let settleMS = Double(DispatchTime.now().uptimeNanoseconds - settleStart) / 1_000_000
                    // Each case has first/warm client passes after shared repository
                    // setup. Later cases intentionally inherit preceding cache activity.
                    for workload in workloads {
                        let coldPressure = Self.pressure()
                        let coldUsage = Self.usage()
                        let coldStart = DispatchTime.now().uptimeNanoseconds
                        let coldRetries = try await Self.run(workload, endpoint: endpoint, root: context.rootURL.path)
                        let coldElapsed = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000
                        let coldCPU = Self.usage().cpu - coldUsage.cpu
                        try await Self.quiesce(context.window.workspaceFileContextStore)
                        let beforePressure = Self.pressure()
                        let before = Self.usage()
                        let started = DispatchTime.now().uptimeNanoseconds
                        let retries = try await Self.run(workload, endpoint: endpoint, root: context.rootURL.path)
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                        let after = Self.usage()
                        let row: [String: Any] = [
                            "variant": ProcessInfo.processInfo.environment["HOST_AB_VARIANT"] ?? "unknown",
                            "repetition": ProcessInfo.processInfo.environment["HOST_AB_REPETITION"] ?? "unknown",
                            "workload": workload, "wall_ms": elapsed, "cold_wall_ms": coldElapsed, "index_settle_ms": settleMS,
                            "cold_retries": coldRetries, "retries": retries, "cold_cpu_ms": coldCPU,
                            "pressure_cold": coldPressure,
                            "cpu_ms": after.cpu - before.cpu, "peak_rss_bytes": after.rss,
                            "pressure_before": beforePressure, "pressure_after": Self.pressure(),
                            "files": 2048, "search_bytes": searchBytes,
                            "case_order": workloads, "rss_scope": "process_high_water_including_setup_and_prior_cases",
                            "read_lane": MCPDomainToolAdmissionLimits.fileReadConnection,
                            "small_read_lane": MCPDomainToolAdmissionLimits.smallReadConnection,
                            "search_lane": MCPDomainToolAdmissionLimits.fileSearchConnection
                        ]
                        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                        print("HOST_AB_SAMPLE \(String(decoding: data, as: UTF8.self))")
                    }
                    for root in await context.window.workspaceFileContextStore.roots() {
                        await context.window.workspaceFileContextStore.unloadRoot(id: root.id)
                    }
                    await fixture.cleanup()
                } catch {
                    for root in await context.window.workspaceFileContextStore.roots() {
                        await context.window.workspaceFileContextStore.unloadRoot(id: root.id)
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private nonisolated static func quiesce(_ store: WorkspaceFileContextStore) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while true {
                let state = await store.debugCodemapGraphStatusSnapshot()
                let ready = !state.roots.isEmpty && state.roots.allSatisfy {
                    !$0.eligibilityFlightPresent && $0.launch?.taskPresent != true
                        && $0.job?.phase == .complete && $0.job?.workerPresent != true
                        && $0.manifest?.writerActivity?.quiescenceConfirmed != false
                }
                if ready, state.activeGraphIndexBatchCount == 0, state.queuedGraphIndexBatchCount == 0,
                   state.drainingGraphIndexTaskCount == 0 { return }
                if ContinuousClock.now >= deadline {
                    print("HOST_AB_INVALID_GRAPH \(state)")
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        private nonisolated static func run(_ workload: String, endpoint: PersistentMCPTestEndpoint, root: String) async throws -> Int {
            let count = workload == "mixed" ? 24 : workload == "read" ? 24 : 1
            return try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0 ..< count {
                    group.addTask {
                        let name: String
                        let arguments: [String: Any]
                        let expected: String
                        switch workload == "mixed" ? index % 4 : workload == "read" ? 0 : 1 {
                        case 0:
                            name = "read_file"
                            arguments = ["path": root + "/Sources/Read\(index).txt"]
                            expected = "host capacity evidence line"
                        case 1:
                            name = "file_search"
                            arguments = ["pattern": "needle", "mode": "content", "regex": false, "max_results": 1_000_000, "count_only": true]
                            expected = "327680"
                        case 2:
                            name = "get_code_structure"
                            arguments = ["paths": [root + "/Sources/File\(index).swift"], "size": "small"]
                            expected = "Benchmark_\(index)"
                        default:
                            name = "git"
                            arguments = ["op": "status", "repo_root": root]
                            expected = "git-probe.txt"
                        }
                        var retries = 0
                        while true {
                            let response = try await endpoint.callTool(name: name, arguments: arguments, timeoutSeconds: 120)
                            let retryableSearch = response.rawJSON.contains("search_backpressure")
                            let retryableStructure = name == "get_code_structure"
                                && (response.rawJSON.contains("partial") || response.rawJSON.contains("not in the code graph yet"))
                                && !response.rawJSON.contains(expected)
                            if retryableSearch || retryableStructure, retries < 3 {
                                // Honor production retry/partial-readiness contracts; final
                                // content assertions remain exact. Include retry wait/CPU.
                                retries += 1
                                try await Task.sleep(for: .seconds(1))
                                continue
                            }
                            try check(response.rawJSON, contains: expected)
                            return retries
                        }
                    }
                }
                var retries = 0
                for try await count in group {
                    retries += count
                }
                return retries
            }
        }

        private nonisolated static func check(_ raw: String, contains expected: String?) throws {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            XCTAssertNil(object["error"], raw)
            let result = try XCTUnwrap(object["result"] as? [String: Any], raw)
            XCTAssertNotEqual(result["isError"] as? Bool, true, raw)
            if let expected { XCTAssertTrue(raw.contains(expected), "Missing \(expected): \(raw.prefix(1600))") }
            if expected == "host capacity evidence line" {
                let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
                let text = blocks.compactMap { $0["text"] as? String }.joined()
                XCTAssertEqual(
                    text.components(separatedBy: "host capacity evidence line").count - 1,
                    8192,
                    "Read must return every line, not just a sentinel or truncated prefix"
                )
            }
        }

        private nonisolated static func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        private nonisolated static func usage() -> (cpu: Double, rss: Int) {
            var own = rusage()
            var children = rusage()
            getrusage(RUSAGE_SELF, &own)
            getrusage(RUSAGE_CHILDREN, &children)
            func ms(_ value: timeval) -> Double {
                Double(value.tv_sec) * 1000 + Double(value.tv_usec) / 1000
            }
            return (ms(own.ru_utime) + ms(own.ru_stime) + ms(children.ru_utime) + ms(children.ru_stime), own.ru_maxrss)
        }

        private nonisolated static func pressure() -> [String: Any] {
            var level: Int32 = 0
            var size = MemoryLayout<Int32>.size
            sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
            let host = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, host) }
            let status = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(host, HOST_VM_INFO64, $0, &count)
                }
            }
            var limit = rlimit()
            getrlimit(RLIMIT_NOFILE, &limit)
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 65536)
            let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
            var pageSize: vm_size_t = 0
            host_page_size(host, &pageSize)
            return [
                "open_fds": Int(bytes) / MemoryLayout<proc_fdinfo>.stride,
                "fd_limit": limit.rlim_cur,
                "load_1m": load[0],
                "memory_level": level,
                "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                "vm_status": status,
                "free_pages": stats.free_count,
                "inactive_pages": stats.inactive_count,
                "compressor_pages": stats.compressor_page_count,
                "compressions": stats.compressions,
                "swapouts": stats.swapouts,
                "page_size": pageSize
            ]
        }
    }
#endif
