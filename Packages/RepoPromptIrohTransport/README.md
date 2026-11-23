# RepoPrompt Iroh transport

This is RepoPrompt CE’s independently owned Swift/Rust transport package. It does not resolve source code from the standalone RepoPrompt Remote repository. The two applications maintain separate implementations and interoperate through versioned wire contracts and compatibility fixtures.

## Ownership and dependency boundary

- Swift owns application authorization, Keychain identity persistence, pairing, and protocol routing.
- Rust owns the Iroh endpoint, authenticated endpoint IDs, bounded QUIC request streams, connection staging, and deadlines.
- The caller supplies the 32-byte endpoint secret. Rust does not generate, persist, serialize, or log it.
- `repoprompt-remote/1` is the ALPN. Frames use a four-byte big-endian length and are rejected before allocation above 1,048,576 bytes.

## Reproducible source inputs

The package commits the complete provenance needed to reproduce the binary:

- Rust 1.92.0 (`rust/rust-toolchain.toml`)
- Iroh 1.0.3
- UniFFI 0.31.2
- the locked Cargo graph (`rust/Cargo.lock`)
- checked-in generated Swift bindings

Third-party notices are in `THIRD_PARTY-NOTICES.md`.

## Binary delivery

Ordinary SwiftPM and Xcode builds consume the immutable CE-owned release asset declared in `Package.swift`. The approximately 293 MiB uncompressed XCFramework is not stored in Git and a clean checkout does not run Cargo. The release ZIP is content-verified by SwiftPM’s checksum.

To reproduce the artifact locally:

```bash
Packages/RepoPromptIrohTransport/Scripts/build-xcframework.sh
Packages/RepoPromptIrohTransport/Scripts/verify-xcframework.sh
```

The build requires the pinned Rust toolchain, Apple macOS/iOS targets, Xcode command-line tools, and UniFFI dependencies resolved from `Cargo.lock`. Local outputs under `Artifacts/`, `.build/`, and `rust/target/` are ignored.

## Tests

```bash
swift test --package-path Packages/RepoPromptIrohTransport
swift run repoprompt-iroh-spike --self-test
```

The automated loopback verifies stable caller-owned identity, authenticated peer IDs, bounded framed echo, shutdown, and Swift/Rust bridge behavior. Physical Wi-Fi, cellular, relay, sleep/wake, and reboot validation remain explicit release gates rather than claims inferred from Simulator tests.
