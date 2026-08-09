#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${1:-repoprompt-ce-headless:local}"
docker build --file Dockerfile.headless --tag "$IMAGE" .
docker run --rm --entrypoint /usr/local/bin/repoprompt-mcp "$IMAGE" --version
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
    test "$(id -u)" = 65532
    test "$(id -g)" = 65532
    test -w "$CODEX_HOME"
    test ! -e "$CODEX_HOME/auth.json"
    test -z "${CODEX_API_KEY+x}"
    test "$REPOPROMPT_CODEX_COMMAND" = /opt/codex/bin/codex
    test "$REPOPROMPT_CODEX_EXTERNALLY_SANDBOXED" = 1
    test -x /opt/codex/bin/codex-code-mode-host
    test -x /opt/codex/codex-path/rg
    test -x /opt/codex/codex-resources/bwrap
    test -x /opt/codex/codex-resources/zsh/bin/zsh
    test -r /usr/share/doc/repoprompt-ce/codex/LICENSE
    test -r /usr/share/doc/repoprompt-ce/codex/NOTICE
    test -r /usr/share/doc/repoprompt-ce/codex/ZSH-LICENCE
    test "$(codex --version)" = "codex-cli 0.147.0"
    codex --ask-for-approval never --sandbox workspace-write exec --ephemeral --skip-git-repo-check --json --help >/dev/null
    codex --dangerously-bypass-approvals-and-sandbox exec --ephemeral --skip-git-repo-check --json --help >/dev/null
'
python3 Scripts/test_linux_headless_mcp.py docker "$IMAGE"
