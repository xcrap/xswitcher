# XSwitcher: `make` builds build/XSwitcher.app, `make install` copies it to /Applications.
#
# Signing: by default the app is signed ad hoc ("-"), and macOS forgets its
# Accessibility permission after every rebuild. To keep it, put your own
# certificate in local.mk (not in git), e.g.
#   SIGN_ID = Developer ID Application: Your Name (TEAMID)
-include local.mk

VERSION     := 0.3.1
BUILD       := 4
UPDATE_REPO ?= xcrap/xswitcher
SIGN_ID     ?= -
SIGN_FLAGS  := $(if $(filter -,$(SIGN_ID)),,--options runtime --timestamp)

APP         := build/XSwitcher.app
HELPER       = $(APP)/Contents/Helpers/XSwitcher Settings.app
ICON        := build/XSwitcher.icns
AGENT_SRC   := $(wildcard agent/*.c)
AGENT_HDR   := $(wildcard agent/*.h)
APP_SRC     := $(wildcard app/*.swift)
ARCHS       := arm64 x86_64
MIN_MACOS   := 13.0
PLIST_VARS   = -e 's|__VERSION__|$(VERSION)|' -e 's|__BUILD__|$(BUILD)|' -e 's|__UPDATE_REPO__|$(UPDATE_REPO)|'

all: $(APP)

# XSwitcher's main program: the switcher (C, no AppKit).
build/xswitcher-agent: $(AGENT_SRC) $(AGENT_HDR) Makefile
	@mkdir -p build
	clang -Os -Wall -Wextra -Wno-deprecated-declarations -mmacosx-version-min=$(MIN_MACOS) \
	  $(foreach a,$(ARCHS),-arch $(a)) -DXS_VERSION='"$(VERSION)"' -o $@ $(AGENT_SRC) \
	  -framework ApplicationServices -framework Carbon -framework CoreFoundation -lobjc -Wl,-dead_strip
	strip -x $@

# The Settings window and menu bar icon (Swift/AppKit).
build/XSwitcherSettings: $(APP_SRC) Makefile
	@mkdir -p build
	for a in $(ARCHS); do \
	  swiftc -O -swift-version 5 -target $$a-apple-macos$(MIN_MACOS) -o build/XSwitcherSettings-$$a $(APP_SRC) || exit 1; \
	done
	lipo -create $(foreach a,$(ARCHS),build/XSwitcherSettings-$(a)) -output $@

$(ICON): bundle/XSwitcher.png
	@mkdir -p build/XSwitcher.iconset
	@for size in 16 32 128 256 512; do \
	  sips -z $$size $$size $< --out build/XSwitcher.iconset/icon_$${size}x$${size}.png >/dev/null || exit 1; \
	  double=$$((size * 2)); \
	  sips -z $$double $$double $< --out build/XSwitcher.iconset/icon_$${size}x$${size}@2x.png >/dev/null || exit 1; \
	done
	iconutil -c icns build/XSwitcher.iconset -o $@

$(APP): build/xswitcher-agent build/XSwitcherSettings $(ICON) bundle/Info.plist bundle/Settings-Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources "$(HELPER)/Contents/MacOS"
	cp build/xswitcher-agent $@/Contents/MacOS/
	cp $(ICON) $@/Contents/Resources/
	sed $(PLIST_VARS) bundle/Info.plist > $@/Contents/Info.plist
	cp build/XSwitcherSettings "$(HELPER)/Contents/MacOS/XSwitcher Settings"
	sed $(PLIST_VARS) bundle/Settings-Info.plist > "$(HELPER)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_ID)" $(SIGN_FLAGS) "$(HELPER)"
	codesign --force --sign "$(SIGN_ID)" $(SIGN_FLAGS) $@
	@echo "built $@"

ZIP            := build/XSwitcher-$(VERSION).zip
NOTARY_PROFILE ?= xswitcher-notary

zip: $(APP)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "zipped $(ZIP)"

# Sends the app to Apple, staples the ticket and re-zips it for a release.
# One-time setup (stores your Apple ID login in the keychain):
#   xcrun notarytool store-credentials xswitcher-notary --team-id <TEAMID>
notarize: $(APP)
	@test "$(SIGN_ID)" != "-" || { echo "notarize needs a Developer ID: set SIGN_ID in local.mk"; exit 1; }
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	spctl --assess --type execute -vv $(APP)
	@echo "notarized $(ZIP)"

install: $(APP)
	@pkill -x "XSwitcher Settings" || true
	@pkill -x xswitcher-agent || true
	rm -rf /Applications/XSwitcher.app
	cp -R $(APP) /Applications/
	@echo "installed /Applications/XSwitcher.app"

clean:
	rm -rf build

.PHONY: all zip notarize install clean
