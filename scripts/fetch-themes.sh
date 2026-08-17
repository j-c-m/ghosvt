#!/usr/bin/env bash
# Fetch Ghostty theme files from the latest j-c-m/terminal-themes release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/Sources/Ghosvt/Resources/themes"
TMP="${ROOT}/.theme-fetch"
REPO="j-c-m/terminal-themes"
mkdir -p "${DEST}" "${TMP}"
cd "${TMP}"

API="https://api.github.com/repos/${REPO}/releases/latest"
META="$(curl -fsSL "${API}")"
TAG="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"${META}")"
if [[ -z "${TAG}" ]]; then
  echo "ghosvt: could not read latest ${REPO} tag" >&2
  exit 1
fi

STAMP="${DEST}/.release"
if [[ -f "${STAMP}" && "$(tr -d '[:space:]' < "${STAMP}")" == "${TAG}" ]]; then
  echo "ghosvt: themes up to date (${TAG})"
  exit 0
fi

echo "ghosvt: fetching ${REPO} ${TAG} ghostty themes"

unpack_7z() {
  local archive="$1"
  if command -v 7zz >/dev/null 2>&1; then
    7zz x -y -o"${TMP}/ghostty-out" "${archive}" >/dev/null
    return 0
  fi
  if command -v 7z >/dev/null 2>&1; then
    7z x -y -o"${TMP}/ghostty-out" "${archive}" >/dev/null
    return 0
  fi
  return 1
}

rm -rf "${TMP}/ghostty-out" "${TMP}/zipball"
mkdir -p "${TMP}/ghostty-out"

if curl -fL -o ghostty.7z "https://github.com/${REPO}/releases/download/${TAG}/ghostty.7z" \
  && unpack_7z ghostty.7z; then
  SRC="${TMP}/ghostty-out"
  if [[ -d "${SRC}/ghostty" ]]; then SRC="${SRC}/ghostty"; fi
else
  echo "ghosvt: 7z unpack failed; using release zipball"
  curl -fL -o zipball.zip "https://github.com/${REPO}/archive/refs/tags/${TAG}.zip"
  mkdir -p zipball
  unzip -q zipball.zip -d zipball
  SRC="$(find zipball -type d -path '*/build/ghostty' | head -1)"
  if [[ -z "${SRC}" ]]; then
    echo "ghosvt: no build/ghostty in zipball" >&2
    exit 1
  fi
fi

# Drop previous slugs; keep the directory.
find "${DEST}" -mindepth 1 -maxdepth 1 ! -name '.release' -exec rm -rf {} +
for f in "${SRC}"/*; do
  [[ -f "${f}" ]] || continue
  base="$(basename "${f}")"
  [[ "${base}" == .* ]] && continue
  cp -f "${f}" "${DEST}/${base}"
done
printf '%s\n' "${TAG}" > "${STAMP}"

echo "OK: ${DEST} ($(find "${DEST}" -type f ! -name '.release' | wc -l | tr -d ' ') themes, ${TAG})"
