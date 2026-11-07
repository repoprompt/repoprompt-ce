#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python="${REPOPROMPT_GUI_PYTHON:-$repo_root/.venv-linux-gui/bin/python}"
if [[ ! -x "$python" ]]; then python=python3; fi
engine="${REPOPROMPT_GUI_ENGINE:-$repo_root/.build/release/repoprompt-mcp}"
export PYTHONPATH="$repo_root/Apps/RepoPromptLinux/src${PYTHONPATH:+:$PYTHONPATH}"
exec "$python" -m repoprompt_gui --engine "$engine" "$@"
