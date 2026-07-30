#!/usr/bin/env bash
set -euo pipefail

# Keep source-build and package-resolution subprocesses independent of ambient
# GitHub credentials.
exec env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    -u SOURCE_GH_TOKEN \
    "$@"
