# Routing Profile Publication Boundary

**Status:** Bundled profiles only. Remote profile publication, transport, cache, verification, trust management, activation, scheduling, and Settings status/update controls have been retired. No profile metadata request is made. This document records the current boundary; the former remote-feed design is not an operational plan or approval to restore that path.

## Bundled source and authority

`Sources/RepoPrompt/Infrastructure/AI/RoutingProfiles/BundledRoutingProfiles.swift` is the sole routing-profile source. `RoutingProfileDocumentDecoder` strictly rejects duplicate JSON keys, unknown fields/schema, invalid identities/references, unsupported matchers, and out-of-bounds content before `RoutingModelProfileResolver` consumes the document. The resolver adds advisory descriptions, family guidance, cost/evidence, and uncertainty to provider-authorized model options. A missing or unknown profile never excludes a provider model, creates an executable model, or authorizes an effort.

`RoutingModelProfileSnapshot` owns the immutable bundled resolver, SHA-256 content digest, and content-derived identity. `RoutingProfileStore` exposes that bundled snapshot synchronously. Candidate capture records the identity so stale work can be rejected if the bundled content changes in a later app build. Provider catalogs remain the only authority for executable targets and supported parameters/efforts.

There is no remote manifest verifier or trust store, HTTP transport, cache, updater/coordinator, profile activation stream, expiry fallback, or app lifecycle integration. No RepoPrompt-hosted feed, endpoint, signature authority, or remote replacement is defined. Do not add or infer one as part of model discovery: the Settings **Update models** action reuses provider-owned discovery and does not update routing profiles.

## Settings compatibility

`scalarPreferences.modelRoutingProfiles.remoteUpdatesDisabled` and `lastCheckAt` are deprecated, inert optional fields retained solely for schema-v12 Codable and rollback compatibility. The content-derived schema fence continues to require v12 when either field is present. Current code has no active manager reader/writer for these values and does not create, update, clear, or eagerly migrate them. Unrelated settings edits must preserve both fields and the schema fence so an older v12-aware app can still decode the document.

See [model routing](model-routing.md) and [settings persistence](settings-persistence.md) for the bundled annotation and legacy persistence contracts.
