# OpenAI Codex 0.147.0

RepoPrompt CE packages the complete official OpenAI Codex standalone package
for the selected macOS architecture and installs the official platform package
from `@openai/codex@0.147.0` in the Linux headless container image. Codex is
licensed under Apache-2.0. The packages also include the upstream Zsh 5.9
executable under `codex-resources/zsh/bin/zsh`.

- Source: https://github.com/openai/codex
- Pinned release: https://github.com/openai/codex/releases/tag/rust-v0.147.0
- License at the pinned tag: https://github.com/openai/codex/blob/rust-v0.147.0/LICENSE
- Notice at the pinned tag: https://github.com/openai/codex/blob/rust-v0.147.0/NOTICE
- macOS package/checksum contract: `Vendor/Codex/manifest.json`
- Linux container package pin and extraction contract: `Dockerfile.headless`
- Bundled Zsh source: https://github.com/zsh-users/zsh/tree/zsh-5.9
- Bundled Zsh licence: https://github.com/zsh-users/zsh/blob/zsh-5.9/LICENCE

`LICENSE` and `NOTICE` are exact copies from the pinned Codex tag, and
`ZSH-LICENCE` is an exact copy of the Zsh 5.9 `LICENCE` file. The
application preserves the full standalone package layout and the upstream
signatures of its primary macOS executables. The Linux image preserves the
standalone `bin`, `codex-path`, and `codex-resources` layout selected by the
official npm platform package; Node and npm are build-stage dependencies and
are not copied into the runtime image. This directory is copied into the image
at `/usr/share/doc/repoprompt-ce/codex`.

For the 0.147.0 rotation, the pinned upstream `LICENSE` and `NOTICE` are
byte-identical to the prior 0.145.0 copies. The verified candidate manifest also
retains the Zsh 5.9 path and unchanged normalized payload, so no legal text
changed; only this version/source inventory and its checksum were refreshed.
