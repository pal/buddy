.PHONY: app run install test e2e e2e-audio zip clean icon

INSTALL_DIR ?= /Applications

app:
	scripts/build-app.sh

run: app
	open build/Buddy.app

# Builds and installs Buddy. A locally built app has no quarantine flag, so it opens
# without Gatekeeper warnings.
install: app
	rm -rf "$(INSTALL_DIR)/Buddy.app"
	ditto build/Buddy.app "$(INSTALL_DIR)/Buddy.app"
	open "$(INSTALL_DIR)/Buddy.app"

test:
	swift test

# End-to-end tests of the real app with sentences fed in as recognized text.
e2e: app
	python3 e2e/run_e2e.py --mode inject

# End-to-end tests with real speech: needs the BlackHole virtual audio device as
# default input and output, and a Swedish voice (see README).
e2e-audio: app
	python3 e2e/run_e2e.py --mode audio

zip: app
	ditto -c -k --keepParent build/Buddy.app build/Buddy.zip

icon:
	python3 scripts/make_icon.py

clean:
	rm -rf .build build
