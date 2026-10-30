.PHONY: test build package verify

test:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

build:
	./scripts/build.sh

package:
	./scripts/package.sh

verify:
	./scripts/verify.sh
