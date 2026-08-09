#!/usr/bin/env bash
# Copy Ghostty's terminfo database into the app Resources tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/Sources/Ghosvt/Resources/terminfo"

SRC=""
if [[ -d /Applications/Ghostty.app/Contents/Resources/terminfo ]]; then
  SRC="/Applications/Ghostty.app/Contents/Resources/terminfo"
elif [[ -d "${ROOT}/Vendor/ghostty/zig-out/share/terminfo" ]]; then
  SRC="${ROOT}/Vendor/ghostty/zig-out/share/terminfo"
else
  echo "No Ghostty terminfo found. Install Ghostty.app or build ghostty with terminfo."
  exit 1
fi

rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -a "${SRC}/." "${DEST}/"

echo "Installed terminfo from ${SRC} → ${DEST}"
find "${DEST}" -type f -o -type l
export TERMINFO="${DEST}"
infocmp -x xterm-ghostty >/dev/null && echo "OK: infocmp xterm-ghostty"
