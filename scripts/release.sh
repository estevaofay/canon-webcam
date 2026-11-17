#!/bin/bash
# Publishes the version in VERSION as a GitHub release with the DMG attached.
# See docs/RELEASING.md. `make release-check` runs every check and builds the
# DMG without tagging, pushing or publishing anything.
set -euo pipefail

cd "$(dirname "$0")/.."
dry_run=false
[[ ${1:-} == --dry-run ]] && dry_run=true

version=$(tr -d '[:space:]' < VERSION)
tag=v$version
dmg=dist/canon-webcam-$version.dmg
fail() { echo "error: $*" >&2; exit 1; }

echo "==> checking the repository for $tag"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.3 (it is \"$version\")"
[[ $(git branch --show-current) == main ]] || fail "release from main (you are on $(git branch --show-current))"
[[ -z $(git status --porcelain) ]] || fail "commit or stash your changes first"
git fetch --quiet origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || $dry_run \
    || fail "main and origin/main differ: push or pull first"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag already exists"
command -v gh >/dev/null || fail "the GitHub CLI (gh) is needed: brew install gh"

# The release notes are this version's section of CHANGELOG.md.
notes=$(awk -v v="$version" '
    $0 ~ "^## " { if (found) exit; if ($2 == v) { found = 1; next } }
    found { print }' CHANGELOG.md)
[[ -n ${notes//[[:space:]]/} ]] || fail "CHANGELOG.md has no \"## $version\" section"

echo "==> running the tests"
swift test 2>&1 | tail -n 3

echo "==> building the DMG"
scripts/make-app.sh --dmg
sha=$(shasum -a 256 "$dmg" | awk '{ print $1 }')

notes_file=$(mktemp)
trap 'rm -f "$notes_file"' EXIT
cat > "$notes_file" <<NOTES
$notes

### Install

1. Install [OBS Studio](https://obsproject.com/download), open it once, click **Start Virtual Camera**, and allow its camera extension in System Settings. Then quit OBS.
2. Download **canon-webcam-$version.dmg** below, open it, and drag canon-webcam to Applications.
3. The app isn't signed with an Apple Developer ID: the first time, open **System Settings → Privacy & Security** and click **Open Anyway**.

Needs an Apple silicon Mac with macOS 27 or later. Full instructions are in the [README](https://github.com/estevaofay/canon-webcam#install).

SHA-256 of the DMG: \`$sha\`
NOTES

if $dry_run; then
    echo "==> dry run: would tag $tag at $(git rev-parse --short HEAD), push it, and publish:"
    cat "$notes_file"
    echo "$dmg"
    exit 0
fi

echo "==> tagging and pushing $tag"
git tag -a "$tag" -m "canon-webcam $version"
git push origin main "$tag"

echo "==> publishing the GitHub release"
gh release create "$tag" "$dmg" --title "canon-webcam $version" --notes-file "$notes_file" --verify-tag
