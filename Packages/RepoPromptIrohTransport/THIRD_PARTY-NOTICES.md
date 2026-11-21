# Direct third-party notices for the Iroh transport spike

The complete resolved dependency names and versions are pinned in `rust/Cargo.lock`. This isolated development artifact directly depends on:

- **iroh 1.0.3** — Copyright 2025 Number 0, Inc.; dual licensed MIT OR Apache-2.0: <https://github.com/n0-computer/iroh>
- **UniFFI 0.31.2** — Mozilla Public License 2.0: <https://github.com/mozilla/uniffi-rs>
- **Tokio 1.47.1** — MIT license: <https://github.com/tokio-rs/tokio>
- **zeroize 1.9.0** — Apache-2.0 OR MIT: <https://github.com/RustCrypto/utils/tree/master/zeroize>
- **once_cell 1.21.3** — MIT OR Apache-2.0: <https://github.com/matklad/once_cell>
- **serde_json 1.0.145** — MIT OR Apache-2.0: <https://github.com/serde-rs/json>
- **thiserror 2.0.17** — MIT OR Apache-2.0: <https://github.com/dtolnay/thiserror>

This notice records the spike's direct inputs; it is not yet the production application's exhaustive binary-license inventory. Production acceptance remains gated on generating and reviewing a complete transitive inventory from the locked graph.
