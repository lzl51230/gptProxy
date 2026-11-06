.PHONY: test build package verify

test:
	./scripts/build-core.sh
	$${CARGO:-$$HOME/.cargo/bin/cargo} test --manifest-path core/Cargo.toml --locked --target-dir build/rust
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

build:
	./scripts/build.sh

package:
	./scripts/package.sh

verify:
	./scripts/verify.sh
