#!/usr/bin/env bash
set -euo pipefail

# build-dmg.sh — Build, sign, and package Caddie into a DMG
# Based on proven pipeline from Esper project

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/Build/Products/Release/Caddie.app"
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | tr -d ' "' | cut -d: -f2)
DMG_NAME="Caddie-${VERSION}.dmg"

echo "=== Building Caddie $VERSION ==="

# --- 1. Generate Xcode project ---
echo "==> Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

# --- 2. Build Release ---
echo "==> Building Release..."
xcodebuild build \
    -project Caddie.xcodeproj \
    -scheme Caddie \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    | tail -3

if [[ ! -d "$APP" ]]; then
    echo "ERROR: Build failed — $APP not found"
    exit 1
fi

# --- 3. Detect signing identity ---
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "ERROR: No Developer ID Application certificate found"
    echo "  Install from developer.apple.com or use Xcode > Settings > Accounts"
    exit 1
fi
echo "==> Signing with: $SIGN_IDENTITY"

CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)

# --- 4. Sign all Mach-O binaries in Frameworks ---
echo "==> Signing embedded frameworks..."
while read -r f; do
    if file "$f" | grep -q "Mach-O"; then
        codesign "${CODESIGN_ARGS[@]}" "$f"
    fi
done < <(find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \))

# Sign XPC services
find "$APP/Contents/Frameworks" -name "*.xpc" -type d | while read -r xpc; do
    codesign "${CODESIGN_ARGS[@]}" "$xpc"
done

# Sign helper apps (e.g., Sparkle Updater.app)
find "$APP/Contents/Frameworks" -name "*.app" -type d | while read -r app; do
    codesign "${CODESIGN_ARGS[@]}" "$app"
done

# Sign frameworks
find "$APP/Contents/Frameworks" -name "*.framework" -type d | while read -r fw; do
    codesign "${CODESIGN_ARGS[@]}" "$fw"
done

# --- 5. Sign main app with entitlements ---
echo "==> Signing main app..."
codesign "${CODESIGN_ARGS[@]}" \
    --entitlements "$PROJECT_DIR/Resources/Caddie.entitlements" \
    "$APP"

# --- 6. Verify ---
echo "==> Verifying signatures..."
codesign --verify --deep --strict "$APP" || { echo "ERROR: App signature invalid"; exit 1; }
CODESIGN_INFO=$(codesign -d --verbose=2 "$APP" 2>&1)
echo "$CODESIGN_INFO" | grep -q "flags=0x10000(runtime)" || { echo "ERROR: Hardened runtime not enabled"; exit 1; }
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>&1)
echo "$ENTITLEMENTS" | grep -q "audio-input" || { echo "ERROR: Audio entitlement missing"; exit 1; }
echo "    All signatures valid."

# --- 7. Stage for DMG ---
STAGING=$(mktemp -d)
trap "rm -rf '$STAGING'" EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# --- 8. Create DMG ---
echo "==> Creating $DMG_NAME..."
rm -f "$PROJECT_DIR/$DMG_NAME"
hdiutil create \
    -volname "Caddie" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$PROJECT_DIR/$DMG_NAME"

echo ""
echo "=== Build complete: $DMG_NAME ==="
ls -lh "$PROJECT_DIR/$DMG_NAME"
