#if os(Linux)
/// Shipped Linux MCP executable version. CI verifies it against
/// `version.env`; the macOS executable keeps its existing source.
let CLI_VERSION = "1.3.0"
#endif
