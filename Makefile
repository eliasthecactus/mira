BIN := .build/debug/Mira

.PHONY: build test e2e run connect test-pattern list doctor app dist icon release clean

build:
	swift build

test:
	swift test

# Full pipeline against the local mock sink (no hardware needed)
e2e:
	tools/e2e.sh

# Menu bar app (debug build)
run: build
	$(BIN)

# Headless: make connect IP=192.168.1.42 [ARGS="--no-audio --verbose"]
connect: build
	$(BIN) connect $(IP) $(ARGS)

# Headless with the generated test pattern: make test-pattern IP=192.168.1.42
test-pattern: build
	$(BIN) connect $(IP) --test-pattern --verbose $(ARGS)

list: build
	$(BIN) list

doctor: build
	$(BIN) doctor

# build/Mira.app for this Mac only (fast)
app:
	ARCHS="$(shell uname -m)" scripts/package.sh

# Universal DMG + zip + checksums + Homebrew cask in dist/ (what the release workflow runs)
# SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=... make dist   for a notarized build
dist:
	scripts/package.sh

# Regenerate Support/AppIcon.icns
icon:
	swift tools/make_icon.swift Support/AppIcon.icns

# Bump version, commit and tag: make release VERSION=0.3.0
release:
	scripts/bump.sh $(VERSION)

clean:
	swift package clean
	rm -rf build dist
