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

validate_stable_release_context() {
    local actual_bundle_id="$1"
    local actual_team_id="$2"
    local actual_migration_phase="$3"
    local actual_sign_identity="${4:-}"
    local required

    local required_nonempty=(
        REPOPROMPT_STABLE_RELEASE_CONTEXT
        ROLLOUT_CHANNEL
        ROLLOUT_ROLE
        ROLLOUT_IDENTITY
        ROLLOUT_INSTALLATION_TYPE
        EXPECTED_APP_BUNDLE_ID
        EXPECTED_APP_TEAM_ID
        EXPECTED_APP_REQUIREMENT
        EXPECTED_PROVISIONING_PROFILE_APPLICATION_IDENTIFIER
        EXPECTED_SIGN_IDENTITY
        EXPECTED_SIGNING_MODE
    )
    for required in "${required_nonempty[@]}"; do
        if [[ -z "${!required:-}" ]]; then
            printf 'ERROR: Missing required Stable release context value: %s\n' "$required" >&2
            return 1
        fi
    done
    for required in \
        EXPECTED_INSTALLER_TEAM_ID \
        EXPECTED_INSTALLER_IDENTITY \
        EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID \
        EXPECTED_MIGRATION_ANCHOR_TEAM_ID \
        EXPECTED_MIGRATION_ANCHOR_REQUIREMENT \
        EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY; do
        if [[ "${!required+x}" != "x" ]]; then
            printf 'ERROR: Missing required Stable release context field: %s\n' "$required" >&2
            return 1
        fi
    done

    [[ "$REPOPROMPT_STABLE_RELEASE_CONTEXT" == "stable-rollout-v1" ]] || {
        printf 'ERROR: Unsupported Stable release context contract: %s\n' \
            "$REPOPROMPT_STABLE_RELEASE_CONTEXT" >&2
        return 1
    }
    [[ "$ROLLOUT_CHANNEL" == "stable" ]] || {
        printf 'ERROR: Stable release context channel mismatch: expected stable, got %s\n' \
            "$ROLLOUT_CHANNEL" >&2
        return 1
    }
    [[ "$ROLLOUT_INSTALLATION_TYPE" == "application" ]] || {
        printf 'ERROR: Stable release context must describe an application artifact\n' >&2
        return 1
    }
    [[ -z "$EXPECTED_INSTALLER_TEAM_ID" && -z "$EXPECTED_INSTALLER_IDENTITY" ]] || {
        printf 'ERROR: Legacy/preparer Stable release context must not select an Installer identity\n' >&2
        return 1
    }
    case "$ROLLOUT_ROLE:$ROLLOUT_IDENTITY:$actual_migration_phase" in
        legacy:legacy:disabled)
            [[ -z "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID" && \
               -z "$EXPECTED_MIGRATION_ANCHOR_TEAM_ID" && \
               -z "$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT" && \
               -z "$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY" ]] || {
                printf 'ERROR: Legacy Stable release context must not select a migration anchor\n' >&2
                return 1
            }
            ;;
        preparer:legacy:legacy-preparer)
            [[ -n "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID" && \
               -n "$EXPECTED_MIGRATION_ANCHOR_TEAM_ID" && \
               -n "$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT" && \
               -n "$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY" ]] || {
                printf 'ERROR: Preparer Stable release context requires the complete migration-anchor identity\n' >&2
                return 1
            }
            ;;
        *)
            printf 'ERROR: Stable release context role/identity/phase mismatch: %s/%s/%s\n' \
                "$ROLLOUT_ROLE" "$ROLLOUT_IDENTITY" "$actual_migration_phase" >&2
            return 1
            ;;
    esac
    [[ "$actual_bundle_id" == "$EXPECTED_APP_BUNDLE_ID" ]] || {
        printf 'ERROR: Stable application bundle identifier mismatch: expected %s, got %s\n' \
            "$EXPECTED_APP_BUNDLE_ID" "$actual_bundle_id" >&2
        return 1
    }
    [[ "$actual_team_id" == "$EXPECTED_APP_TEAM_ID" ]] || {
        printf 'ERROR: Stable application Team ID mismatch: expected %s, got %s\n' \
            "$EXPECTED_APP_TEAM_ID" "$actual_team_id" >&2
        return 1
    }
    [[ "$EXPECTED_PROVISIONING_PROFILE_APPLICATION_IDENTIFIER" == \
       "$EXPECTED_APP_TEAM_ID.$EXPECTED_APP_BUNDLE_ID" ]] || {
        printf 'ERROR: Stable provisioning-profile identifier is inconsistent with the application identity\n' >&2
        return 1
    }
    if [[ -n "$actual_sign_identity" && "$actual_sign_identity" != "$EXPECTED_SIGN_IDENTITY" ]]; then
        printf 'ERROR: Stable application signing identity mismatch: expected %s, got %s\n' \
            "$EXPECTED_SIGN_IDENTITY" "$actual_sign_identity" >&2
        return 1
    fi
}


validate_resolved_migration_anchor_identity() {
    local actual_identifier="$1"
    local actual_team_id="$2"
    if [[ -z "${EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID:-}" || \
          -z "${EXPECTED_MIGRATION_ANCHOR_TEAM_ID:-}" ]]; then
        printf 'ERROR: Resolved migration-anchor identity is incomplete\n' >&2
        return 1
    fi
    [[ "$actual_identifier" == "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID" ]] || {
        printf 'ERROR: Identity migration anchor identifier mismatch: expected %s, got %s\n' \
            "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID" "${actual_identifier:-<missing>}" >&2
        return 1
    }
    [[ "$actual_team_id" == "$EXPECTED_MIGRATION_ANCHOR_TEAM_ID" ]] || {
        printf 'ERROR: Identity migration anchor team mismatch: expected %s, got %s\n' \
            "$EXPECTED_MIGRATION_ANCHOR_TEAM_ID" "${actual_team_id:-<missing>}" >&2
        return 1
    }
}

load_release_metadata_with_identity_projection() {
    local metadata_root="$1"
    local approved_source_root="$2"
    local scripts_root="$3"
    local archive_contract="${4:-}"
    local assignments

    load_release_metadata "$metadata_root" || return
    case "$archive_contract" in
    "") return 0 ;;
    tip-rollout-v1)
        [[ -n "$approved_source_root" ]] || {
            printf 'ERROR: Tip release identity projection requires an approved source root\n' >&2
            return 1
        }
        [[ -f "$approved_source_root/tip-rollout.json" ]] || {
            printf 'ERROR: Missing approved Tip rollout declaration\n' >&2
            return 1
        }
        assignments="$(
            python3 "$scripts_root/stable_rollout.py" packaging-context \
                --declaration "$approved_source_root/tip-rollout.json" \
                --policy "$scripts_root/apple_identity_policy.json" \
                --version-env "$approved_source_root/version.env"
        )" || return
        eval "$assignments"
        [[ "$ROLLOUT_CHANNEL" == "tip" ]] || {
            printf 'ERROR: Tip release identity projection requires a Tip rollout declaration\n' >&2
            return 1
        }
        ;;
    *)
        printf 'ERROR: Unsupported REPOPROMPT_TIP_ARCHIVE_CONTRACT: %s\n' "$archive_contract" >&2
        return 1
        ;;
    esac
}
