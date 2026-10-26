import SwiftUI

/// Explicit, endpoint-bound risk acceptance, not a transport-security promise.
struct ProviderHTTPConsentView: View {
    let endpoint: String
    @Binding var consentEndpoint: String?

    var body: some View {
        if ProviderEndpointConsent.isRemoteHTTP(endpoint) {
            VStack(alignment: .leading, spacing: 6) {
                Text("This remote endpoint uses unencrypted HTTP. Credentials and request content can be read or altered in transit. Prefer HTTPS.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Toggle("I accept sending credentials and content without encryption to this endpoint", isOn: Binding(
                    get: { consentEndpoint == ProviderEndpointConsent.endpointIdentity(endpoint) },
                    set: { accepted in
                        consentEndpoint = accepted ? ProviderEndpointConsent.endpointIdentity(endpoint) : nil
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                Text("Consent applies only to this configured endpoint. Redirects and proxy routing are not secured by this setting; local HTTP is not guaranteed to stay local.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
