.PHONY: setup build test release dmg notarize clean

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

# Build release, sign, and create DMG
dmg:
	./scripts/build-dmg.sh

# Notarize, staple, and prepare for distribution
notarize:
	./scripts/release.sh

# Clean build artifacts
clean:
	rm -rf build
	rm -f *.dmg *.sha256
	xcodebuild clean -project Caddie.xcodeproj -scheme Caddie 2>/dev/null || true
