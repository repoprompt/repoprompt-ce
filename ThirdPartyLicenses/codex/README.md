# OpenAI Codex 0.164.0

RepoPrompt CE packages the complete official OpenAI Codex standalone package
for the selected macOS architecture. Codex is licensed under Apache-2.0. The
package includes the Codex native voice runtime under `codex-resources/`. The
voice runtime dynamically links GStreamer, GLib, Opus, PCRE2/SLJIT, libffi,
proxy-libintl, and zlib. The 0.164.0 packages no longer include bundled Zsh.

- Source: https://github.com/openai/codex
- Pinned release: https://github.com/openai/codex/releases/tag/rust-v0.164.0
- License at the pinned tag: https://github.com/openai/codex/blob/rust-v0.164.0/LICENSE
- Notice at the pinned tag: https://github.com/openai/codex/blob/rust-v0.164.0/NOTICE
- Package/checksum contract: `Vendor/Codex/manifest.json`
- Bundled voice notice and source provenance: `VOICE-NOTICE.md` and `VOICE-SOURCES.json`
- Bundled voice licences: the `VOICE-*` files in this directory

`LICENSE` and `NOTICE` are exact copies from the pinned Codex tag. The `VOICE-*`
files are exact copies of the notice, source manifest, and licence files shipped
inside the official 0.164.0 macOS package. The application preserves the full
standalone package layout and pins every upstream-signed Mach-O.

For the 0.164.0 rotation, upstream `LICENSE` and `NOTICE` and the packaged
voice notice, source manifest, and licences remain byte-identical to 0.159.0.
The obsolete Zsh licence is removed with the executable. The native voice
runtime and its legal inventory remain included deliberately; `SHA256SUMS`
covers this complete flat inventory.
