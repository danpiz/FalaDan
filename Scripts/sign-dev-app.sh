#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

REQUIRE_DEVELOPER_ID=false
if [[ "${1:-}" == "--require-developer-id" ]]; then
    REQUIRE_DEVELOPER_ID=true
    shift
fi

APP=${1:?"Usage: $0 [--require-developer-id] <path-to-app>"}
ENTITLEMENTS="$ROOT/build/FalaDan.entitlements"

if [[ ! -d "$APP" ]]; then
    echo "App bundle not found: $APP" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Entitlements not found: $ENTITLEMENTS" >&2
    exit 1
fi

find_developer_id_identity() {
    security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}'
}

# The local self-signed identity from Scripts/setup-dev-signing.sh, if it exists.
#
# Found automatically so a dev build never silently falls back to ad-hoc signing.
# That matters more than it sounds: an ad-hoc signature has no certificate, so the
# app's designated requirement pins a cdhash instead — and the cdhash changes on
# every build, which silently voids the Accessibility grant while System Settings
# continues to show the app ticked. The symptom is the hotkey doing nothing for no
# visible reason.
find_local_dev_identity() {
    security find-identity -v -p codesigning \
        | awk -F'"' '/FalaDan Dev Signing/ {print $2; exit}'
}

choose_identity() {
    if [[ -n "${FALADAN_DEV_CODESIGN_IDENTITY:-}" && "${FALADAN_DEV_CODESIGN_IDENTITY}" != "-" ]]; then
        printf '%s\n' "$FALADAN_DEV_CODESIGN_IDENTITY"
        return
    fi

    if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
        printf '%s\n' "$CODESIGN_IDENTITY"
        return
    fi

    local developer_id
    developer_id=$(find_developer_id_identity)
    if [[ -n "$developer_id" ]]; then
        printf '%s\n' "$developer_id"
        return
    fi

    if [[ -n "${DEV_CODESIGN_IDENTITY:-}" && "${DEV_CODESIGN_IDENTITY}" != "-" ]]; then
        printf '%s\n' "$DEV_CODESIGN_IDENTITY"
        return
    fi

    local local_dev
    local_dev=$(find_local_dev_identity)
    if [[ -n "$local_dev" ]]; then
        printf '%s\n' "$local_dev"
        return
    fi

    printf '%s\n' "-"
}

IDENTITY=$(choose_identity)
if [[ "$REQUIRE_DEVELOPER_ID" == true && "$IDENTITY" == "-" ]]; then
    echo "No Developer ID Application identity found." >&2
    exit 1
fi

echo "==> Signing ${APP} with: ${IDENTITY}"

sign_if_present() {
    local item="$1"
    [[ -e "$item" ]] || return 0
    codesign --force --sign "$IDENTITY" "$item"
}

sign_if_present "$APP/Contents/Frameworks/whisper.framework"

codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

if [[ "$REQUIRE_DEVELOPER_ID" == true ]]; then
    signature_info=$(codesign -dvv "$APP" 2>&1)
    if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_info"; then
        echo "Expected a Developer ID Application signature, but ${APP} was signed differently." >&2
        exit 1
    fi
fi
