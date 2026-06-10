#!/usr/bin/env bash
set -euo pipefail

# release.sh — Notarize, staple, and prepare Caddie for distribution
# Based on proven pipeline from Esper project

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | tr -d ' "' | cut -d: -f2)
DMG_NAME="Caddie-${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
KEYCHAIN_PROFILE="Caddie"

# --- Pre-flight checks ---
echo "=== Caddie Release $VERSION ==="

if [[ ! -f "$DMG_PATH" ]]; then
    echo "DMG not found. Building first..."
    "$SCRIPT_DIR/build-dmg.sh"
fi

# Verify keychain profile exists
xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" > /dev/null 2>&1 || {
    echo "ERROR: Keychain profile '$KEYCHAIN_PROFILE' not found."
    echo "  Run: xcrun notarytool store-credentials $KEYCHAIN_PROFILE"
    exit 1
}

# --- Notarize ---
echo "=== Notarizing DMG ==="
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait \
    --timeout 30m 2>&1)
echo "$NOTARY_OUTPUT"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
    echo "=== Stapling notarization ticket ==="
    xcrun stapler staple "$DMG_PATH"

    # Regenerate checksum after stapling (stapling modifies the DMG)
    shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
    echo ""
    echo "=== Release ready ==="
    echo "  DMG:      $DMG_PATH"
    echo "  Checksum: $DMG_PATH.sha256"
    ls -lh "$DMG_PATH"
    cat "$DMG_PATH.sha256"
else
    SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -o 'id: [a-f0-9-]*' | head -1 | cut -d' ' -f2)
    echo ""
    echo "ERROR: Notarization failed."
    echo "  Run: xcrun notarytool log $SUBMISSION_ID --keychain-profile $KEYCHAIN_PROFILE"
    exit 1
fi
