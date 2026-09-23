# OpenAI Codex 0.156.0

RepoPrompt CE packages the complete official OpenAI Codex standalone package
for the selected macOS architecture. Codex is licensed under Apache-2.0. The
package also includes the upstream Zsh 5.9 executable and the Codex native voice
runtime under `codex-resources/`. The voice runtime dynamically links GStreamer,
GLib, Opus, PCRE2/SLJIT, libffi, proxy-libintl, and zlib.

- Source: https://github.com/openai/codex
- Pinned release: https://github.com/openai/codex/releases/tag/rust-v0.156.0
- License at the pinned tag: https://github.com/openai/codex/blob/rust-v0.156.0/LICENSE
- Notice at the pinned tag: https://github.com/openai/codex/blob/rust-v0.156.0/NOTICE
- Package/checksum contract: `Vendor/Codex/manifest.json`
- Bundled Zsh source: https://github.com/zsh-users/zsh/tree/zsh-5.9
- Bundled Zsh licence: https://github.com/zsh-users/zsh/blob/zsh-5.9/LICENCE
- Bundled voice notice and source provenance: `VOICE-NOTICE.md` and `VOICE-SOURCES.json`
- Bundled voice licences: the `VOICE-*` files in this directory

`LICENSE` and `NOTICE` are exact copies from the pinned Codex tag, and
`ZSH-LICENCE` is an exact copy of the Zsh 5.9 `LICENCE` file. The `VOICE-*`
files are exact copies of the notice, source manifest, and licence files shipped
inside the official 0.156.0 macOS package. The application preserves the full
standalone package layout and pins every upstream-signed Mach-O.

For the 0.156.0 rotation, upstream `LICENSE`, `NOTICE`, and the Zsh payload are
unchanged from the prior pin. The new native voice runtime and its legal inventory
are included deliberately; `SHA256SUMS` covers this complete flat inventory.
