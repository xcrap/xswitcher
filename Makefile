# XSwitcher: `make` builds build/XSwitcher.app, `make install` copies it to /Applications.
VERSION     := 0.2.0
BUILD       := 2
UPDATE_REPO ?=

APP         := build/XSwitcher.app
AGENT_SRC   := $(wildcard agent/*.c)
AGENT_HDR   := $(wildcard agent/*.h)
APP_SRC     := $(wildcard app/*.swift)
ARCHS       := arm64 x86_64
MIN_MACOS   := 13.0

all: $(APP)

build/xswitcher-agent: $(AGENT_SRC) $(AGENT_HDR) Makefile
	@mkdir -p build
	clang -Os -Wall -Wextra -Wno-deprecated-declarations -mmacosx-version-min=$(MIN_MACOS) \
	  $(foreach a,$(ARCHS),-arch $(a)) -DXS_VERSION='"$(VERSION)"' -o $@ $(AGENT_SRC) \
	  -framework ApplicationServices -framework Carbon -framework CoreFoundation -Wl,-dead_strip
	strip -x $@

build/XSwitcher: $(APP_SRC) Makefile
	@mkdir -p build
	for a in $(ARCHS); do \
	  swiftc -O -swift-version 5 -target $$a-apple-macos$(MIN_MACOS) -o build/XSwitcher-$$a $(APP_SRC) || exit 1; \
	done
	lipo -create $(foreach a,$(ARCHS),build/XSwitcher-$(a)) -output $@

$(APP): build/xswitcher-agent build/XSwitcher bundle/Info.plist bundle/local.xswitcher.agent.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Library/LaunchAgents $@/Contents/Resources
	cp build/XSwitcher build/xswitcher-agent $@/Contents/MacOS/
	sed -e 's|__VERSION__|$(VERSION)|' -e 's|__BUILD__|$(BUILD)|' -e 's|__UPDATE_REPO__|$(UPDATE_REPO)|' \
	  bundle/Info.plist > $@/Contents/Info.plist
	cp bundle/local.xswitcher.agent.plist $@/Contents/Library/LaunchAgents/
	codesign --force --sign - --identifier local.xswitcher.agent $@/Contents/MacOS/xswitcher-agent
	codesign --force --sign - $@
	@echo "built $@"

install: $(APP)
	rm -rf /Applications/XSwitcher.app
	cp -R $(APP) /Applications/
	@echo "installed /Applications/XSwitcher.app"

clean:
	rm -rf build

.PHONY: all install clean
