#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ ! -f Vendor/ghostty/zig-out/lib/libghostty-vt.a ]]; then
  ./scripts/build-libghostty.sh
fi

# SPM may need --disable-sandbox in restricted environments
swift build --disable-sandbox -c release 2>&1
exec swift run --disable-sandbox -c release