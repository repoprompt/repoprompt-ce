#!/usr/bin/env bash
set -euo pipefail

# SwiftPM recursively initializes the pinned Dart grammar's public test-support
# submodule before target reachability excludes it. Keep its legacy GitHub SSH
# URL on the same host and make the rewrite process-local.
git_config_count="${GIT_CONFIG_COUNT:-0}"
[[ "$git_config_count" =~ ^[0-9]+$ ]] || {
    printf 'ERROR: GIT_CONFIG_COUNT must be a non-negative integer\n' >&2
    exit 1
}
git_config_count=$((10#$git_config_count))

github_https_rewrite_present=0
for ((index = 0; index < git_config_count; index++)); do
    key_name="GIT_CONFIG_KEY_$index"
    value_name="GIT_CONFIG_VALUE_$index"
    if [[ "${!key_name:-}" == "url.https://github.com/.insteadOf" &&
        "${!value_name:-}" == "git@github.com:" ]]; then
        github_https_rewrite_present=1
        break
    fi
done

if ((github_https_rewrite_present == 0)); then
    export "GIT_CONFIG_KEY_${git_config_count}=url.https://github.com/.insteadOf"
    export "GIT_CONFIG_VALUE_${git_config_count}=git@github.com:"
    export GIT_CONFIG_COUNT="$((git_config_count + 1))"
fi

exec env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    -u SOURCE_GH_TOKEN \
    "$@"
