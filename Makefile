.PHONY: setup build test release dmg clean

# Generate Xcode project from project.yml
setup:
	xcodegen generate

# Build debug
build: setup
	xcodebuild build \
		-project Caddie.xcodeproj \
		-scheme Caddie \
		-configuration Debug \
		-destination 'platform=macOS'

# Run tests
test: setup
	xcodebuild test \
		-project Caddie.xcodeproj \
		-scheme Caddie \
		-configuration Debug \
		-destination 'platform=macOS'

# Build release
release: setup
	xcodebuild build \
		-project Caddie.xcodeproj \
		-scheme Caddie \
		-configuration Release \
		-destination 'platform=macOS' \
		-derivedDataPath build

# Create DMG from release build
dmg: release
	@command -v create-dmg >/dev/null || (echo "Install create-dmg: brew install create-dmg" && exit 1)
	@VERSION=$$(grep 'MARKETING_VERSION' project.yml | head -1 | tr -d ' "' | cut -d: -f2); \
	rm -f Caddie-$$VERSION.dmg; \
	create-dmg \
		--volname "Caddie" \
		--window-pos 200 120 \
		--window-size 660 400 \
		--icon-size 160 \
		--icon "Caddie.app" 180 170 \
		--hide-extension "Caddie.app" \
		--app-drop-link 480 170 \
		--no-internet-enable \
		"Caddie-$$VERSION.dmg" \
		"build/Build/Products/Release/Caddie.app"

# Clean build artifacts
clean:
	rm -rf build
	rm -f *.dmg
	xcodebuild clean -project Caddie.xcodeproj -scheme Caddie 2>/dev/null || true
