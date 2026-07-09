#!/usr/bin/env bash

load_release_metadata() {
    local root="$1"
    local assignments
    assignments="$(
        python3 - "$root/version.env" <<'PYTHON'
import re
import shlex
import sys
from pathlib import Path

patterns = {
    "APP_NAME": r"[A-Za-z0-9._ -]+",
    "DISPLAY_NAME": r"[A-Za-z0-9._ -]+",
    "MARKETING_VERSION": r"[0-9]+(?:\.[0-9]+){2}",
    "BUILD_NUMBER": r"[0-9]{1,4}(?:\.[0-9]{1,2}){0,2}",
    "BUNDLE_ID": r"[A-Za-z0-9.-]+",
    "SIGNING_TEAM_ID": r"[A-Z0-9]+",
}
values = {}
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit(f"invalid release metadata line: {raw_line}")
    key, value = line.split("=", 1)
    if key not in patterns or key in values:
        raise SystemExit(f"invalid or duplicate release metadata key: {key}")
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    if not re.fullmatch(patterns[key], value):
        raise SystemExit(f"invalid release metadata value for {key}")
    values[key] = value

missing = sorted(set(patterns) - set(values))
if missing:
    raise SystemExit(f"missing release metadata keys: {', '.join(missing)}")
for key in patterns:
    print(f"{key}={shlex.quote(values[key])}")
PYTHON
    )" || return
    eval "$assignments"
}
