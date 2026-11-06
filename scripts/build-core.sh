#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CARGO=${CARGO:-"$HOME/.cargo/bin/cargo"}
if [ ! -x "$CARGO" ]; then CARGO=cargo; fi
TASK_TARGET=${1:-$("$HOME/.cargo/bin/rustc" -vV | sed -n 's/^host: //p')}
cd "$PROJECT_DIR/core"
"$HOME/.cargo/bin/rustup" target add "$TASK_TARGET"
"$CARGO" build --locked --release --target "$TASK_TARGET" --target-dir "$PROJECT_DIR/build/rust"
