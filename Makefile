PREFIX ?= $(HOME)/.local

.PHONY: build install uninstall app dmg extension clean

# The command-line tool (captures the DSLR and feeds a virtual camera).
build:
	swift build -c release

install: build
	install -d "$(PREFIX)/bin"
	install .build/release/canon-webcam "$(PREFIX)/bin/canon-webcam"
	@echo "installed $(PREFIX)/bin/canon-webcam (make sure $(PREFIX)/bin is on your PATH)"

uninstall:
	rm -f "$(PREFIX)/bin/canon-webcam"

# The menu bar app: dist/canon-webcam.app, and a DMG to share it.
app:
	scripts/make-app.sh

dmg:
	scripts/make-app.sh --dmg

# The optional "Canon Webcam" Camera Extension + host app. Builds unsigned;
# installing it needs a signed build (see README).
extension:
	cd Extension && xcodegen generate
	xcodebuild -project Extension/CanonWebcam.xcodeproj -scheme CanonWebcam \
		-configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
	@echo "built .build/xcode/Build/Products/Release/CanonWebcam.app (unsigned)"

clean:
	rm -rf .build dist
