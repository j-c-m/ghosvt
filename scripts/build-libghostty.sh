#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="${ROOT}/Vendor/ghostty"

if [[ ! -d "${GHOSTTY}/.git" && ! -f "${GHOSTTY}/build.zig" ]]; then
  echo "Vendor/ghostty missing. Clone ghostty first:"
  echo "  git clone --depth 1 https://github.com/ghostty-org/ghostty.git Vendor/ghostty"
  exit 1
fi

export ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache-global"
export ZIG_LOCAL_CACHE_DIR="${ROOT}/.zig-cache-local"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}" "${ZIG_LOCAL_CACHE_DIR}"

echo "Building libghostty-vt (ReleaseFast)…"
(
  cd "${GHOSTTY}"
  zig build -Demit-lib-vt -Doptimize=ReleaseFast
)

echo "OK: ${GHOSTTY}/zig-out/lib/libghostty-vt.a"
