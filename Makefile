APP := build/Launcher.app
INSTALL_DIR := $(HOME)/Applications

# Ad-hoc by default. Set to a signing identity for a stable one.
SIGN ?= -

.PHONY: app install test clean

app:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Launcher $(APP)/Contents/MacOS/Launcher
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN)" $(APP)

install: app
	mkdir -p "$(INSTALL_DIR)"
	ditto $(APP) "$(INSTALL_DIR)/Launcher.app"

test:
	swift test

clean:
	swift package clean
	rm -rf build
