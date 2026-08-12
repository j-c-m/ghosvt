#!/usr/bin/env bash
# Build Ghosvt.app (Ghostty-shaped Xcode path). Host arch, local/ad-hoc sign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

./scripts/build-libghostty.sh

ARCH="$(uname -m)"
case "${ARCH}" in
  arm64) XC_ARCH=arm64 ;;
  x86_64) XC_ARCH=x86_64 ;;
  *) echo "ghosvt: unsupported arch ${ARCH}" >&2; exit 1 ;;
esac

BUILD_ROOT="${ROOT}/macos/build"
DERIVED="${BUILD_ROOT}/DerivedData"
PRODUCT_DIR="${BUILD_ROOT}/Release"
mkdir -p "${PRODUCT_DIR}"

xcodebuild \
  -project "${ROOT}/macos/Ghosvt.xcodeproj" \
  -scheme Ghosvt \
  -configuration Release \
  -arch "${XC_ARCH}" \
  -derivedDataPath "${DERIVED}" \
  CONFIGURATION_BUILD_DIR="${PRODUCT_DIR}" \
  ONLY_ACTIVE_ARCH=YES \
  build

APP="${PRODUCT_DIR}/Ghosvt.app"
if [[ ! -d "${APP}" ]]; then
  echo "ghosvt: expected app missing: ${APP}" >&2
  exit 1
fi

echo "OK: ${APP}"
