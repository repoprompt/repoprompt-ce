import Darwin
import Foundation

let cli = HeadlessCLI()
let exitCode = await cli.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment
)
if exitCode != 0 {
    Darwin.exit(Int32(exitCode))
}
