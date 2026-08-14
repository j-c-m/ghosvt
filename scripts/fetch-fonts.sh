#!/usr/bin/env bash
# Fetch JetBrains Mono + Nerd Fonts Symbols Only from Ghostty's dependency CDN.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FONTDIR="${ROOT}/Sources/Ghosvt/Resources/Fonts"
TMP="${ROOT}/.font-fetch"
mkdir -p "${FONTDIR}" "${TMP}"
cd "${TMP}"

JB_URL="https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz"
NF_URL="https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz"

curl -fL -o JetBrainsMono-2.304.tar.gz "${JB_URL}"
curl -fL -o NerdFontsSymbolsOnly-3.4.0.tar.gz "${NF_URL}"

rm -rf jb nf
mkdir jb nf
tar -xzf JetBrainsMono-2.304.tar.gz -C jb
tar -xzf NerdFontsSymbolsOnly-3.4.0.tar.gz -C nf

cp -f jb/fonts/ttf/JetBrainsMono-Regular.ttf "${FONTDIR}/"
cp -f jb/fonts/ttf/JetBrainsMono-Bold.ttf "${FONTDIR}/"
cp -f jb/fonts/ttf/JetBrainsMono-Italic.ttf "${FONTDIR}/"
cp -f jb/fonts/ttf/JetBrainsMono-BoldItalic.ttf "${FONTDIR}/"
cp -f jb/fonts/ttf/JetBrainsMono-ExtraBold.ttf "${FONTDIR}/"
cp -f jb/fonts/ttf/JetBrainsMono-ExtraBoldItalic.ttf "${FONTDIR}/"
cp -f nf/SymbolsNerdFont-Regular.ttf "${FONTDIR}/"
cp -f nf/SymbolsNerdFontMono-Regular.ttf "${FONTDIR}/"

[[ -f jb/OFL.txt ]] && cp -f jb/OFL.txt "${FONTDIR}/OFL.txt"
[[ -f jb/AUTHORS.txt ]] && cp -f jb/AUTHORS.txt "${FONTDIR}/AUTHORS.txt"
[[ -f nf/LICENSE ]] && cp -f nf/LICENSE "${FONTDIR}/LICENSE"

echo "Fonts installed to ${FONTDIR}"
ls -lah "${FONTDIR}"/*.ttf
