import RepoPromptCore
import RepoPromptCoreMacOS

enum RuntimeCodeSigningDetector {
    static func currentProcessSigningInfo(
        localSigningExpectation: RuntimeLocalSigningExpectation? = nil
    ) -> RuntimeCodeSigningInfo {
        MacOSRuntimeCodeSigningDetector.currentProcessSigningInfo(
            requirements: RuntimeCodeSigningRequirements(
                developerIDRequirement: RuntimeCodeSigningPolicy.developerIDRequirement,
                appleDevelopmentDebugRequirement: RuntimeCodeSigningPolicy.appleDevelopmentDebugRequirement,
                localCodeIdentifier: RuntimeCodeSigningPolicy.developerIDBundleIdentifier
            ),
            localSigningExpectation: localSigningExpectation
        )
    }
}
