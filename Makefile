BIN := .build/debug/Mira

.PHONY: build run sign clean

build:
	swift build

# Sign with screen-recording entitlement, then run
sign: build
	codesign --force --sign - --entitlements entitlements.plist $(BIN)

run: sign
	$(BIN)

# Direct-connect to adapter IP (skip mDNS discovery)
# Usage: make connect IP=192.168.1.42
connect: sign
	$(BIN) $(IP)

clean:
	swift package clean
