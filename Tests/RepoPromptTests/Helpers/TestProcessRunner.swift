import Foundation

struct TestProcessResult {
    let terminationStatus: Int32
    let output: Data

    var outputText: String {
        String(decoding: output, as: UTF8.self)
    }
}

enum TestProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> TestProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return TestProcessResult(
            terminationStatus: process.terminationStatus,
            output: outputData
        )
    }
}
