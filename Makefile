.PHONY: app run test zip clean icon

app:
	scripts/build-app.sh

run: app
	open build/Buddy.app

test:
	swift test

zip: app
	ditto -c -k --keepParent build/Buddy.app build/Buddy.zip

icon:
	python3 scripts/make_icon.py

clean:
	rm -rf .build build
