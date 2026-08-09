# Embedded fonts (from Ghostty)

Same packages Ghostty embeds via `build.zig.zon` / `src/font/embedded.zig`.

| File | Role |
|------|------|
| `JetBrainsMono-Regular.ttf` | Primary mono |
| `JetBrainsMono-Bold.ttf` | Bold (fallback if ExtraBold missing) |
| `JetBrainsMono-Italic.ttf` | Italic |
| `JetBrainsMono-BoldItalic.ttf` | Bold italic fallback |
| `JetBrainsMono-ExtraBold.ttf` | **SGR bold** face |
| `JetBrainsMono-ExtraBoldItalic.ttf` | **SGR bold + italic** face |
| `JetBrainsMono-Variable.ttf` | Variable (`JetBrainsMono[wght].ttf`) |
| `JetBrainsMono-Italic-Variable.ttf` | Variable italic |
| `SymbolsNerdFont-Regular.ttf` | Ghostty `nerd_fonts_symbols_only` cascade |
| `SymbolsNerdFontMono-Regular.ttf` | Mono nerd symbols (preferred cascade first) |

## Upstream

- JetBrains Mono 2.304: `https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz`
- Nerd Fonts Symbols Only 3.4.0: `https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz`

Refresh:

```bash
# from repo root
./scripts/fetch-fonts.sh
```

Licenses: `OFL.txt` (JetBrains Mono), `LICENSE` (Nerd Fonts Symbols).
