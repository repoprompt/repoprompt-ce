#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
source "$ROOT_DIR/version.env"
set +a

LOCAL_SELF_SIGNED_CERTIFICATE_NAME="RepoPrompt CE Local Self-Signed Code Signing"
LOCAL_PRODUCTION_INSTALL_DIR="${LOCAL_PRODUCTION_INSTALL_DIR:-/Applications}"
LOCAL_PRODUCTION_APP="$LOCAL_PRODUCTION_INSTALL_DIR/$DISPLAY_NAME.app"
LOCAL_CERTIFICATE_DAYS="${LOCAL_CERTIFICATE_DAYS:-3650}"
LOCAL_SIGNING_REQUIREMENT="anchor trusted and identifier \"$BUNDLE_ID\" and certificate leaf[subject.CN] = \"$LOCAL_SELF_SIGNED_CERTIFICATE_NAME\""
TMP_DIR=""
STAGED_DIR=""
STAGED_APP=""
BACKUP_DIR=""
BACKUP_APP=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
    [[ -z "$STAGED_DIR" ]] || rm -rf "$STAGED_DIR"
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
        if [[ ! -e "$LOCAL_PRODUCTION_APP" ]]; then
            mv "$BACKUP_APP" "$LOCAL_PRODUCTION_APP" ||
                printf 'ERROR: Could not restore prior app from backup: %s\n' "$BACKUP_APP" >&2
        else
            printf 'WARNING: Preserving prior app backup after failed replacement: %s\n' "$BACKUP_APP" >&2
        fi
    fi
    [[ -z "$BACKUP_DIR" ]] || rmdir "$BACKUP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

[[ "${CONFIRM_LOCAL_PRODUCTION_INSTALL:-}" == "1" ]] ||
    fail "Set CONFIRM_LOCAL_PRODUCTION_INSTALL=1 to build and replace the local production app in $LOCAL_PRODUCTION_INSTALL_DIR."

for command in codesign ditto openssl plutil security swift; do
    require_command "$command"
done

LOGIN_KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
[[ -n "$LOGIN_KEYCHAIN" && -f "$LOGIN_KEYCHAIN" ]] || fail "Could not resolve the user's default login keychain."

TMP_DIR="$(mktemp -d)"
CERTIFICATE_PEM="$TMP_DIR/repoprompt-ce-local-signing.pem"

find_local_identity() {
    security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null |
        awk -F'\"' -v name="$LOCAL_SELF_SIGNED_CERTIFICATE_NAME" '$2 == name { print $1; exit }' |
        awk '{ print $2 }'
}

trust_existing_certificate_if_present() {
    security find-certificate -c "$LOCAL_SELF_SIGNED_CERTIFICATE_NAME" -p "$LOGIN_KEYCHAIN" > "$CERTIFICATE_PEM" 2>/dev/null || true
    if [[ -s "$CERTIFICATE_PEM" ]]; then
        printf 'Trusting existing local RepoPrompt CE code-signing certificate for code signing. macOS may ask for confirmation.\n'
        security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$CERTIFICATE_PEM"
    fi
}

mint_local_identity() {
    local password
    password="$(openssl rand -hex 24)"
    printf 'Creating user-local RepoPrompt CE self-signed code-signing identity. macOS may ask for confirmation when its trust policy is installed.\n'
    cat > "$TMP_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = distinguished_name
x509_extensions = codesign_extensions
prompt = no

[distinguished_name]
CN = $LOCAL_SELF_SIGNED_CERTIFICATE_NAME
O = RepoPrompt CE Local
OU = Local Build

[codesign_extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF
    openssl req -new -newkey rsa:2048 -x509 -sha256 -days "$LOCAL_CERTIFICATE_DAYS" -nodes \
        -config "$TMP_DIR/openssl.cnf" \
        -out "$CERTIFICATE_PEM" \
        -keyout "$TMP_DIR/repoprompt-ce-local-signing-key.pem"
    local -a pkcs12_args=(-export)
    if { openssl pkcs12 -help 2>&1 || true; } | grep -q -- '-legacy'; then
        pkcs12_args+=(-legacy)
    fi
    openssl pkcs12 "${pkcs12_args[@]}" \
        -out "$TMP_DIR/repoprompt-ce-local-signing.p12" \
        -inkey "$TMP_DIR/repoprompt-ce-local-signing-key.pem" \
        -in "$CERTIFICATE_PEM" \
        -name "$LOCAL_SELF_SIGNED_CERTIFICATE_NAME" \
        -passout "pass:$password"
    security import "$TMP_DIR/repoprompt-ce-local-signing.p12" \
        -k "$LOGIN_KEYCHAIN" \
        -P "$password" \
        -T /usr/bin/codesign \
        -T /usr/bin/security
    security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$CERTIFICATE_PEM"
}

SIGN_IDENTITY="$(find_local_identity)"
if [[ -z "$SIGN_IDENTITY" ]]; then
    trust_existing_certificate_if_present
    SIGN_IDENTITY="$(find_local_identity)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    mint_local_identity
    SIGN_IDENTITY="$(find_local_identity)"
fi
[[ -n "$SIGN_IDENTITY" ]] || fail "The user-local RepoPrompt CE code-signing identity is not valid after installation."
printf 'Using user-local code-signing identity: %s\n' "$LOCAL_SELF_SIGNED_CERTIFICATE_NAME"

LOCAL_SELF_SIGNED_RELEASE=1 \
    SIGN_IDENTITY="$SIGN_IDENTITY" \
    "$ROOT_DIR/Scripts/package_app.sh" release

BUILD_DIR="$(swift build -c release --show-bin-path)"
SOURCE_APP="$BUILD_DIR/$APP_NAME.app"
[[ -d "$SOURCE_APP" ]] || fail "Missing packaged local production app: $SOURCE_APP"
[[ "$(plutil -extract RepoPromptSigningMode raw "$SOURCE_APP/Contents/Info.plist")" == "local-self-signed" ]] ||
    fail "Packaged app is missing the local self-signed runtime marker."
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$SOURCE_APP"

if pgrep -f "$LOCAL_PRODUCTION_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    fail "Quit $DISPLAY_NAME before replacing $LOCAL_PRODUCTION_APP."
fi

mkdir -p "$LOCAL_PRODUCTION_INSTALL_DIR"
STAGED_DIR="$(mktemp -d "$LOCAL_PRODUCTION_INSTALL_DIR/.$DISPLAY_NAME.app.installing.XXXXXX")"
STAGED_APP="$STAGED_DIR/$DISPLAY_NAME.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SIGNING_REQUIREMENT" "$STAGED_APP"
if [[ -e "$LOCAL_PRODUCTION_APP" ]]; then
    BACKUP_DIR="$(mktemp -d "$LOCAL_PRODUCTION_INSTALL_DIR/.$DISPLAY_NAME.app.backup.XXXXXX")"
    BACKUP_APP="$BACKUP_DIR/$DISPLAY_NAME.app"
    mv "$LOCAL_PRODUCTION_APP" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$LOCAL_PRODUCTION_APP"
STAGED_APP=""
rmdir "$STAGED_DIR"
STAGED_DIR=""
if [[ -n "$BACKUP_APP" ]]; then
    rm -rf "$BACKUP_APP"
    rmdir "$BACKUP_DIR"
    BACKUP_APP=""
    BACKUP_DIR=""
fi

printf 'Installed local self-signed production app: %s\n' "$LOCAL_PRODUCTION_APP"
printf 'This app is local-only, not notarized, and must not be distributed or uploaded to GitHub Releases.\n'
