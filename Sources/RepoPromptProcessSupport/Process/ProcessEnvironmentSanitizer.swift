import Foundation

/// Shared process-environment sanitization for child process launches.
///
/// Phase 1 only centralizes the policy and constants. Existing launch callers are
/// migrated in later phases so security detection and spawn-time scrubbing cannot
/// drift on dynamic-loader environment keys. Sanitization treats all `DYLD_` and
/// `__XPC_DYLD_` variables as dynamic-loader state.
package enum ProcessEnvironmentSanitizer {
    package static let dynamicLoaderInsertLibrariesKey = "DYLD_INSERT_LIBRARIES"

    package static let dynamicLoaderKeys: Set<String> = [
        dynamicLoaderInsertLibrariesKey,
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_ROOT_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH"
    ]

    static let dynamicLoaderKeyPrefixes: [String] = [
        "DYLD_",
        "__XPC_DYLD_"
    ]

    package static func sanitizedForChildLaunch(
        _ environment: [String: String],
        additionalRemovedKeys: Set<String> = []
    ) -> [String: String] {
        environment.filter { key, _ in
            !isDynamicLoaderKey(key) && !additionalRemovedKeys.contains(key)
        }
    }

    package static func isDynamicLoaderKey(_ key: String) -> Bool {
        if dynamicLoaderKeys.contains(key) {
            return true
        }
        return dynamicLoaderKeyPrefixes.contains { key.hasPrefix($0) }
    }
}
