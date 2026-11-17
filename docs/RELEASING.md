# Releasing

A release is a tag `vX.Y.Z` on `main` plus a GitHub release with the DMG
attached. `scripts/release.sh` does all of it from your Mac.

## Once

- Xcode Command Line Tools, `brew install libusb libgphoto2 gh`
- `gh auth login` with push access to this repository

## Each release

1. Pick the version ([semantic versioning](https://semver.org): fixes bump the
   last number, new features the middle one, breaking changes the first).
2. Put it in `VERSION`, and add a `## X.Y.Z` section at the top of
   `CHANGELOG.md` saying what changed, written for people using the app.
3. Commit both on `main` ("Release X.Y.Z") and push.
4. `make release-check` runs every check, the tests, and builds the DMG, then
   prints the release notes without publishing anything.
5. Install the DMG from `dist/` on your Mac and check it streams (open the
   panel, join a test call), then quit it.
6. `make release` tags `vX.Y.Z`, pushes the tag, and publishes the GitHub
   release with `dist/canon-webcam-X.Y.Z.dmg` and its SHA-256.

The script refuses to run off `main`, with uncommitted changes, when `main`
isn't pushed, when the tag already exists, or when `CHANGELOG.md` has no
section for the version.

## Notes

- The DMG is signed ad hoc, not with a Developer ID, so first launch needs
  **Open Anyway**, and macOS asks for camera access again after each update.
  Signing and notarizing need a paid Apple Developer account (see
  `docs/roadmap.md`).
- The DMG bundles Homebrew's libusb from the Mac that builds it, so the app
  needs the same macOS version or later (macOS 27 today; see `docs/roadmap.md`).
