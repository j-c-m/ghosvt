# ghosvt

Full-screen macOS virtual terminals on **libghostty-vt**, with a Metal host.

Linux-style multi-console: **⌘F1…Fn** and **⌘1…n** switch VTs. Each VT runs a banner then either your shell (`console-mode = shell`, default) or **`/usr/bin/login`** (`console-mode = login`). Exit respawns that VT.

## Requirements

- macOS 14+
- Xcode / Swift 6 toolchain
- Zig (same major as Ghostty; see [ghostty build docs](https://ghostty.org/docs/install/build))
- Non-sandboxed app (setuid `login` will not work under App Sandbox)

## Terminfo

Bundled Ghostty terminfo under `Sources/Ghosvt/Resources/terminfo/`:

- `TERM=xterm-ghostty`
- `TERMINFO=<bundle>/Resources/terminfo`
- `COLORTERM=truecolor`
- `TERM_PROGRAM=ghosvt`

`console-mode = login` uses `login -p` so TERM/TERMINFO reach the user shell. `console-mode = shell` runs `$SHELL -l` with the host environment. Refresh terminfo from Ghostty.app:

```bash
./scripts/fetch-terminfo.sh
```

## Build

```bash
# once: vendor ghostty (if not present)
git clone --depth 1 https://github.com/ghostty-org/ghostty.git Vendor/ghostty

./scripts/build-libghostty.sh
swift build -c release
swift run -c release
# or
./scripts/run.sh
```

## Fonts

Embedded (same Ghostty CDN pins):

- **JetBrains Mono** 2.304 — Regular / Bold / ExtraBold / Italic / BoldItalic / ExtraBoldItalic + variable
- **Nerd Fonts Symbols Only** 3.4.0 — cascade for icons (`SymbolsNerdFont` + mono)
- Terminal SGR bold draws with **ExtraBold** (falls back to Bold if missing)

Loaded at runtime from `Sources/Ghosvt/Resources/Fonts/`. Refresh with:

```bash
./scripts/fetch-fonts.sh
```

## Config

Ghostty-style file: **`~/.config/ghosvt/config`**

```
# ~/.config/ghosvt/config
vt-count = 6
font-size = 16
scrollback-limit = 50000000
console-mode = shell
max-aspect = 3:2
```

`scrollback-limit` is bytes (Ghostty `scrollback-limit` / `scrollback-limit-bytes`; default **50 MB**). Use `unlimited` for no byte cap. Zero disables scrollback.

`console-mode` is **`shell`** (default for now: banner + `$SHELL -l`) or **`login`** (banner + `/usr/bin/login -p`).

`scroll-to-bottom` matches Ghostty (default **`keystroke, no-output`**). Comma list of `keystroke` / `no-keystroke` / `output` / `no-output`.

`max-aspect` caps content width/height (default **3:2**). Accepts `3:2`, `3/2`, or a float like `1.5`. Wider screens letterbox with background bars.

Missing file → defaults. No Application Support path.

## Keys

| Binding | Action |
|---------|--------|
| **⌘1…⌘9** | Switch to VT 1…9 |
| **⌘0** | VT 10 (if `vt-count` ≥ 10) |
| **⌘F1…⌘F*n*** | Same |
| **⌘← / ⌘→** | Previous / next VT |
| **⌘Q** | Quit |

## Status

- Fullscreen Metal host
- libghostty-vt + PTY + banner + `console-mode` (login / shell) + respawn
- Multi-VT manager (lazy spawn), **⌘1… / ⌘F1…** switch
- **PR2 Metal renderer finished:** dirty-gated rebuilds, cursor styles + blink, underline/faint, poll budget, ASCII prewarm, Nerd glyph fallback
- Letterboxed content on ultrawide (`max-aspect`, default 3:2)
- Embedded JetBrains Mono (+ Nerd symbol faces)
- Config loader (`~/.config/ghosvt/config`)

**Next:** PR4 bouncy scroll physics.

## License

App code: TBD. libghostty-vt: Ghostty project license.
