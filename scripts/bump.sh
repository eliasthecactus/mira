#!/bin/bash
# Prepares a release: sets the version in Support/Info.plist, commits and tags.
#   scripts/bump.sh 0.3.0            (or 0.3.0-beta.1)
# Then: git push && git push origin v0.3.0   -> GitHub Actions builds and publishes it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/bump.sh <version>}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "not a semantic version: $VERSION"; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "Add a '## [$VERSION]' section to CHANGELOG.md first."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree not clean - commit first."; exit 1; }

/usr/libexec/PlistBuddy -c "Set :MiraVersion $VERSION" \
                        -c "Set :CFBundleShortVersionString ${VERSION%%-*}" Support/Info.plist
git add Support/Info.plist
git commit -m "Release v$VERSION"
git tag -a "v$VERSION" -m "Mira $VERSION"
echo "Tagged v$VERSION. Publish with: git push && git push origin v$VERSION"
