#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GH_TOKEN:?Set GH_TOKEN to publish a release}"
: "${GH_REPO:?Set GH_REPO to the intended repository}"
: "${RELEASE_TAG:?Set RELEASE_TAG to the release version tag}"

assets="${1:-build/bin/releases}"
files=("$assets/blank_-macos-arm64.zip" "$assets/blank_-macos-intel.zip" "$assets/SHA256SUMS")
for file in "${files[@]}"; do
  test -f "$file"
done

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  gh release upload "$RELEASE_TAG" "${files[@]}" --clobber
  gh release edit "$RELEASE_TAG" --draft=false
else
  gh release create "$RELEASE_TAG" "${files[@]}" --verify-tag \
    --title "blank_ $RELEASE_TAG" --notes-file .github/release-notes.md
fi
