#if DEBUG
    import CryptoKit
    import Foundation

    /// Path-free, bounded evidence describing policy-digest assembly. This value is
    /// diagnostic carriage only; it is deliberately excluded from policy identity
    /// equality and hashing.
    struct GitWorkspacePolicyCanonicalizationDiagnostics: Hashable {
        enum CommonAuthorityState: String, Hashable {
            case missing
            case directory
            case regular
        }

        enum ExternalAuthorityState: String, Hashable {
            case unset
            case missing
            case present
        }

        enum Completeness: String, Hashable {
            case complete
            case incomplete
        }

        enum ComparisonClassification: String, Hashable {
            case canonicalEquivalentAfterReachabilityFiltering
            case semanticInputDifference
            case incomplete
            case incoherent
        }

        enum Constituent: String, CaseIterable, Hashable {
            case rootNeutralPolicyConfig
            case commonInfoExclude
            case canonicalIgnoreFooter
            case externalExcludes
            case configuredIgnorePolicy
            case commonInfoAttributes
            case canonicalAttributeFooter
            case externalAttributes
            case attributePolicy
            case sparsePolicy
            case canonicalization
            case committedControls
        }

        struct CommonAuthorityIdentity: Hashable {
            let state: CommonAuthorityState
            let digest: String
        }

        struct CanonicalControlFooterIdentity: Hashable {
            let digest: String
            let recordCount: Int
        }

        struct ExternalAuthorityIdentity: Hashable {
            let state: ExternalAuthorityState
            let identityDigest: String
            let byteCount: Int
        }

        struct ConstituentComparison: Hashable {
            let constituent: Constituent
            let matched: Bool
        }

        struct Comparison: Hashable {
            let classification: ComparisonClassification
            let constituentComparisons: [ConstituentComparison]
            let base: GitWorkspacePolicyCanonicalizationDiagnostics?
            let target: GitWorkspacePolicyCanonicalizationDiagnostics?
        }

        let rootNeutralPolicyConfigByteCount: Int
        let rootNeutralPolicyConfigSHA256: String
        let commonInfoExclude: CommonAuthorityIdentity
        let canonicalIgnoreFooter: CanonicalControlFooterIdentity
        let externalExcludes: ExternalAuthorityIdentity
        let configuredIgnorePolicyDigest: String
        let commonInfoAttributes: CommonAuthorityIdentity
        let canonicalAttributeFooter: CanonicalControlFooterIdentity
        let externalAttributes: ExternalAuthorityIdentity
        let attributePolicyDigest: String
        let sparsePolicyDigest: String
        let canonicalizationPolicyVersion: String
        let prunedRootCount: Int
        let prunedRootSummarySHA256: String
        let completeness: Completeness
        let committedControlCount: Int
        let committedControlSummarySHA256: String

        init(
            rootNeutralPolicyConfigByteCount: Int,
            rootNeutralPolicyConfigSHA256: String,
            commonInfoExclude: CommonAuthorityIdentity,
            canonicalIgnoreFooter: CanonicalControlFooterIdentity,
            externalExcludes: ExternalAuthorityIdentity,
            configuredIgnorePolicyDigest: String,
            commonInfoAttributes: CommonAuthorityIdentity,
            canonicalAttributeFooter: CanonicalControlFooterIdentity,
            externalAttributes: ExternalAuthorityIdentity,
            attributePolicyDigest: String,
            sparsePolicyDigest: String,
            canonicalizationPolicyVersion: String,
            prunedRootCount: Int,
            prunedRootSummarySHA256: String,
            completeness: Completeness,
            committedControlCount: Int,
            committedControlSummarySHA256: String
        ) {
            self.rootNeutralPolicyConfigByteCount = rootNeutralPolicyConfigByteCount
            self.rootNeutralPolicyConfigSHA256 = rootNeutralPolicyConfigSHA256
            self.commonInfoExclude = commonInfoExclude
            self.canonicalIgnoreFooter = canonicalIgnoreFooter
            self.externalExcludes = externalExcludes
            self.configuredIgnorePolicyDigest = configuredIgnorePolicyDigest
            self.commonInfoAttributes = commonInfoAttributes
            self.canonicalAttributeFooter = canonicalAttributeFooter
            self.externalAttributes = externalAttributes
            self.attributePolicyDigest = attributePolicyDigest
            self.sparsePolicyDigest = sparsePolicyDigest
            self.canonicalizationPolicyVersion = canonicalizationPolicyVersion
            self.prunedRootCount = prunedRootCount
            self.prunedRootSummarySHA256 = prunedRootSummarySHA256
            self.completeness = completeness
            self.committedControlCount = committedControlCount
            self.committedControlSummarySHA256 = committedControlSummarySHA256
        }

        /// Domain-separated fingerprint for repository-relative path bytes. Raw
        /// paths never enter the diagnostic model or exported payload.
        static func repositoryRelativePathFingerprint(_ path: String) -> String {
            var material = Data()
            appendLengthPrefixed(Data("rpce-policy-control-path-v1".utf8), to: &material)
            appendLengthPrefixed(Data(path.utf8), to: &material)
            return sha256Hex(material)
        }

        /// Returns nil only when neither side carries diagnostics. A one-sided
        /// value is retained as explicit incomplete evidence for troubleshooting.
        static func comparison(
            base: GitWorkspacePolicyIdentity,
            target: GitWorkspacePolicyIdentity
        ) -> Comparison? {
            let baseDiagnostics = base.canonicalizationDiagnostics
            let targetDiagnostics = target.canonicalizationDiagnostics
            guard baseDiagnostics != nil || targetDiagnostics != nil else { return nil }

            let comparisons = Constituent.allCases.map { constituent in
                ConstituentComparison(
                    constituent: constituent,
                    matched: baseDiagnostics.map { lhs in
                        targetDiagnostics.map { rhs in
                            lhs.matches(rhs, constituent: constituent)
                        } ?? false
                    } ?? false
                )
            }
            let classification: ComparisonClassification
            if baseDiagnostics == nil || targetDiagnostics == nil {
                classification = .incomplete
            } else if let baseDiagnostics, let targetDiagnostics,
                      !baseDiagnostics.isCoherent(with: base)
                      || !targetDiagnostics.isCoherent(with: target)
            {
                classification = .incoherent
            } else if let baseDiagnostics, let targetDiagnostics,
                      !baseDiagnostics.isComplete || !targetDiagnostics.isComplete
            {
                classification = .incomplete
            } else {
                let semanticConstituents = Constituent.allCases.filter { $0 != .canonicalization }
                let semanticInputsMatch = semanticConstituents.allSatisfy { constituent in
                    comparisons.first { $0.constituent == constituent }?.matched == true
                }
                classification = semanticInputsMatch
                    ? .canonicalEquivalentAfterReachabilityFiltering
                    : .semanticInputDifference
            }
            return Comparison(
                classification: classification,
                constituentComparisons: comparisons,
                base: baseDiagnostics,
                target: targetDiagnostics
            )
        }

        private var isComplete: Bool {
            completeness == .complete
        }

        private func isCoherent(with identity: GitWorkspacePolicyIdentity) -> Bool {
            guard rootNeutralPolicyConfigByteCount >= 0,
                  Self.isLowercaseSHA256(rootNeutralPolicyConfigSHA256),
                  Self.isLowercaseSHA256(commonInfoExclude.digest),
                  Self.isLowercaseSHA256(canonicalIgnoreFooter.digest),
                  canonicalIgnoreFooter.recordCount >= 0,
                  Self.externalIdentityIsCoherent(externalExcludes),
                  Self.isLowercaseSHA256(configuredIgnorePolicyDigest),
                  Self.isLowercaseSHA256(commonInfoAttributes.digest),
                  Self.isLowercaseSHA256(canonicalAttributeFooter.digest),
                  canonicalAttributeFooter.recordCount >= 0,
                  Self.externalIdentityIsCoherent(externalAttributes),
                  Self.isLowercaseSHA256(attributePolicyDigest),
                  Self.isLowercaseSHA256(sparsePolicyDigest),
                  !canonicalizationPolicyVersion.isEmpty,
                  prunedRootCount >= 0,
                  Self.isLowercaseSHA256(prunedRootSummarySHA256),
                  committedControlCount >= 0,
                  Self.isLowercaseSHA256(committedControlSummarySHA256),
                  canonicalIgnoreFooter.digest == identity.committedIgnoreControlDigest,
                  configuredIgnorePolicyDigest == identity.configuredIgnoreAuthorityDigest,
                  attributePolicyDigest == identity.attributePolicyDigest,
                  sparsePolicyDigest == identity.sparsePolicyDigest,
                  canonicalizationPolicyVersion == identity.mandatoryIgnorePolicyIdentity
            else { return false }
            return true
        }

        private func matches(_ other: Self, constituent: Constituent) -> Bool {
            switch constituent {
            case .rootNeutralPolicyConfig:
                rootNeutralPolicyConfigByteCount == other.rootNeutralPolicyConfigByteCount
                    && rootNeutralPolicyConfigSHA256 == other.rootNeutralPolicyConfigSHA256
            case .commonInfoExclude:
                commonInfoExclude == other.commonInfoExclude
            case .canonicalIgnoreFooter:
                canonicalIgnoreFooter == other.canonicalIgnoreFooter
            case .externalExcludes:
                externalExcludes == other.externalExcludes
            case .configuredIgnorePolicy:
                configuredIgnorePolicyDigest == other.configuredIgnorePolicyDigest
            case .commonInfoAttributes:
                commonInfoAttributes == other.commonInfoAttributes
            case .canonicalAttributeFooter:
                canonicalAttributeFooter == other.canonicalAttributeFooter
            case .externalAttributes:
                externalAttributes == other.externalAttributes
            case .attributePolicy:
                attributePolicyDigest == other.attributePolicyDigest
            case .sparsePolicy:
                sparsePolicyDigest == other.sparsePolicyDigest
            case .canonicalization:
                canonicalizationPolicyVersion == other.canonicalizationPolicyVersion
                    && completeness == other.completeness
            case .committedControls:
                committedControlCount == other.committedControlCount
                    && committedControlSummarySHA256 == other.committedControlSummarySHA256
            }
        }

        private static func externalIdentityIsCoherent(_ identity: ExternalAuthorityIdentity) -> Bool {
            identity.byteCount >= 0 && isLowercaseSHA256(identity.identityDigest)
        }

        private static func isLowercaseSHA256(_ value: String) -> Bool {
            value.count == 64 && isLowercaseHex(value)
        }

        private static func isLowercaseHex(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { byte in
                (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
            }
        }

        private static func appendLengthPrefixed(_ value: Data, to output: inout Data) {
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
            output.append(value)
        }

        private static func sha256Hex(_ value: Data) -> String {
            SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
