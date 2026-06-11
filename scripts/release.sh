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

    # --- Generate, sign, and attach the Sparkle appcast ---
    # SUFeedURL points at releases/latest/download/appcast.xml, so EVERY future
    # release MUST attach a freshly generated appcast.xml here — otherwise Sparkle
    # auto-updates silently stall on whatever release last carried one.
    echo ""
    echo "=== Generating Sparkle appcast ==="

    # Sparkle tools live in DerivedData (multiple copies possible); pick the first existing.
    SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 \
        -path "*/Caddie-*/SourcePackages/artifacts/sparkle/Sparkle/bin" \
        -type d 2>/dev/null | head -1)
    if [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
        echo "ERROR: Sparkle tools not found in DerivedData. Build the app once (make dmg) so SPM resolves Sparkle, then retry."
        exit 1
    fi

    # generate_appcast scans a directory and would include ANY DMGs present, so
    # stage only the newly stapled DMG in an isolated temp dir.
    APPCAST_STAGING=$(mktemp -d)
    trap 'rm -rf "$APPCAST_STAGING"' EXIT
    cp "$DMG_PATH" "$APPCAST_STAGING/"

    # Sign each enclosure with the Keychain EdDSA key (automatic) and point
    # enclosure URLs at this release's GitHub asset path.
    "$SPARKLE_BIN/generate_appcast" "$APPCAST_STAGING" \
        --download-url-prefix "https://github.com/YashD5291/Caddie/releases/download/v${VERSION}/"
    cp "$APPCAST_STAGING/appcast.xml" "$PROJECT_DIR/appcast.xml"

    # Verify the appcast is valid before attaching it.
    grep -q "sparkle:edSignature" "$PROJECT_DIR/appcast.xml" || {
        echo "ERROR: appcast.xml missing edSignature — Keychain signing failed"
        exit 1
    }
    grep -q "releases/download/v${VERSION}/${DMG_NAME}" "$PROJECT_DIR/appcast.xml" || {
        echo "ERROR: appcast.xml enclosure URL wrong"
        exit 1
    }

    # Attach to the GitHub release if possible; otherwise print manual instructions.
    if command -v gh >/dev/null 2>&1 && gh release view "v${VERSION}" >/dev/null 2>&1; then
        gh release upload "v${VERSION}" "$PROJECT_DIR/appcast.xml" --clobber
        echo "Uploaded appcast.xml to release v${VERSION}."
    else
        echo "NOTE: Attach appcast.xml to the GitHub release v${VERSION} manually (gh not available or release not yet created)."
        echo "      Run after creating the release: gh release upload v${VERSION} \"$PROJECT_DIR/appcast.xml\" --clobber"
    fi

    echo ""
    echo "=== Release ready ==="
    echo "  DMG:      $DMG_PATH"
    echo "  Checksum: $DMG_PATH.sha256"
    echo "  Appcast:  $PROJECT_DIR/appcast.xml"
    ls -lh "$DMG_PATH"
    cat "$DMG_PATH.sha256"
else
    SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -o 'id: [a-f0-9-]*' | head -1 | cut -d' ' -f2)
    echo ""
    echo "ERROR: Notarization failed."
    echo "  Run: xcrun notarytool log $SUBMISSION_ID --keychain-profile $KEYCHAIN_PROFILE"
    exit 1
fi
