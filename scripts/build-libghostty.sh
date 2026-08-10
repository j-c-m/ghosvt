#!/usr/bin/env bash
# Fetch a pinned Ghostty revision, apply ghosvt patches, build libghostty-vt.
#
# Inputs (rebuild when any change):
#   Vendor/ghostty.rev          exact Ghostty commit SHA
#   patches/*.patch             applied in sorted order on top of the pin
#   this script + zig toolchain
#
# Outputs:
#   Vendor/ghostty/             working tree (gitignored)
#   Vendor/ghostty/zig-out/     libghostty-vt.a + headers
#   Vendor/ghostty/.ghosvt-stamp content hash of successful build inputs
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="${ROOT}/Vendor/ghostty"
REV_FILE="${ROOT}/Vendor/ghostty.rev"
PATCH_DIR="${ROOT}/patches"
STAMP_FILE="${GHOSTTY}/.ghosvt-stamp"
ARTIFACT="${GHOSTTY}/zig-out/lib/libghostty-vt.a"
REMOTE_URL="${GHOSTTY_REMOTE:-https://github.com/ghostty-org/ghostty.git}"

if [[ ! -f "${REV_FILE}" ]]; then
  echo "ghosvt: missing ${REV_FILE}" >&2
  echo "  (expected a single Ghostty commit SHA)" >&2
  exit 1
fi

REV="$(tr -d '[:space:]' < "${REV_FILE}")"
if [[ -z "${REV}" || ! "${REV}" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  echo "ghosvt: invalid Ghostty rev in ${REV_FILE}: '${REV}'" >&2
  exit 1
fi

# Sorted list of patch files (may be empty after official search C API lands).
# Portable for macOS /bin/bash 3.2 (no mapfile).
PATCHES=()
if [[ -d "${PATCH_DIR}" ]]; then
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] && PATCHES+=("${_p}")
  done < <(find "${PATCH_DIR}" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | LC_ALL=C sort)
fi

export ZIG_GLOBAL_CACHE_DIR="${ROOT}/.zig-cache-global"
export ZIG_LOCAL_CACHE_DIR="${ROOT}/.zig-cache-local"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}" "${ZIG_LOCAL_CACHE_DIR}" "${ROOT}/Vendor"

# Stamp over pin + patch contents + this script (not wall clock).
compute_stamp() {
  {
    echo "rev=${REV}"
    echo "remote=${REMOTE_URL}"
    echo "script=$(shasum -a 256 "${ROOT}/scripts/build-libghostty.sh" | awk '{print $1}')"
    if command -v zig >/dev/null 2>&1; then
      echo "zig=$(zig version 2>/dev/null || true)"
    fi
    local p
    for p in "${PATCHES[@]+"${PATCHES[@]}"}"; do
      echo "patch=$(basename "${p}")=$(shasum -a 256 "${p}" | awk '{print $1}')"
    done
  } | shasum -a 256 | awk '{print $1}'
}

STAMP="$(compute_stamp)"

if [[ -f "${ARTIFACT}" && -f "${STAMP_FILE}" ]]; then
  if [[ "$(tr -d '[:space:]' < "${STAMP_FILE}")" == "${STAMP}" ]]; then
    echo "ghosvt: libghostty-vt up to date (stamp ${STAMP:0:12}…)"
    echo "OK: ${ARTIFACT}"
    exit 0
  fi
  echo "ghosvt: stamp changed → rebuilding libghostty-vt"
fi

# --- ensure Vendor/ghostty at exact REV (clean) ---
ensure_checkout() {
  if [[ ! -d "${GHOSTTY}/.git" ]]; then
    echo "ghosvt: cloning Ghostty @ ${REV:0:12}…"
    # Prefer a shallow clone of the pin when possible; fall back to full fetch.
    if git clone --filter=blob:none --no-checkout "${REMOTE_URL}" "${GHOSTTY}"; then
      :
    else
      rm -rf "${GHOSTTY}"
      git clone "${REMOTE_URL}" "${GHOSTTY}"
    fi
  fi

  (
    cd "${GHOSTTY}"
    # Make sure we can resolve REV (may need fetch for shallow clones).
    if ! git cat-file -e "${REV}^{commit}" 2>/dev/null; then
      echo "ghosvt: fetching ${REV:0:12}…"
      git fetch --depth 1 origin "${REV}" 2>/dev/null \
        || git fetch origin "${REV}" 2>/dev/null \
        || git fetch --unshallow 2>/dev/null \
        || git fetch origin
    fi
    if ! git cat-file -e "${REV}^{commit}" 2>/dev/null; then
      echo "ghosvt: cannot resolve Ghostty commit ${REV}" >&2
      exit 1
    fi

    # Drop any prior local edits / applied patches so re-apply is clean.
    git checkout -f "${REV}"
    git clean -fdx -e zig-out -e .ghosvt-stamp >/dev/null
    # Detached HEAD at pin is intentional.
    echo "ghosvt: Ghostty @ $(git rev-parse --short HEAD)"
  )
}

ensure_checkout

# --- apply patches (sorted) ---
if ((${#PATCHES[@]} > 0)); then
  echo "ghosvt: applying ${#PATCHES[@]} patch(es)…"
  (
    cd "${GHOSTTY}"
    for p in "${PATCHES[@]}"; do
      echo "  $(basename "${p}")"
      if ! git apply --whitespace=nowarn "${p}"; then
        echo "ghosvt: failed to apply ${p}" >&2
        echo "  pin=${REV}  re-generate patch against that commit" >&2
        exit 1
      fi
    done
  )
else
  echo "ghosvt: no patches in ${PATCH_DIR}"
fi

# --- build ---
echo "ghosvt: building libghostty-vt (ReleaseFast)…"
(
  cd "${GHOSTTY}"
  zig build -Demit-lib-vt -Doptimize=ReleaseFast
)

if [[ ! -f "${ARTIFACT}" ]]; then
  echo "ghosvt: build finished but ${ARTIFACT} missing" >&2
  exit 1
fi

# Verify search shim symbols when the patch set is present.
# Avoid `grep -q` under `pipefail` (SIGPIPE from early close → false negative).
if ((${#PATCHES[@]} > 0)) && command -v nm >/dev/null 2>&1; then
  _nm_out="$(nm "${ARTIFACT}" 2>/dev/null || true)"
  if ! printf '%s\n' "${_nm_out}" | grep -F 'ghostty_screen_search_new' >/dev/null; then
    echo "ghosvt: warning: ghostty_screen_search_new not found in ${ARTIFACT}" >&2
    echo "  search patches may not have linked; check exports" >&2
  fi
  unset _nm_out
fi

printf '%s\n' "${STAMP}" > "${STAMP_FILE}"
echo "OK: ${ARTIFACT}"
echo "ghosvt: stamp ${STAMP:0:12}…"
