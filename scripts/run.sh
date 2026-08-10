#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# Stamp-aware: rebuilds when ghostty.rev / patches / script change.
./scripts/build-libghostty.sh

# SPM may need --disable-sandbox in restricted environments
swift build --disable-sandbox -c release 2>&1
exec swift run --disable-sandbox -c release
