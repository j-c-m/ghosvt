# ghosvt

Fullscreen macOS multi-VT terminal on **libghostty-vt** + **Metal**.

Linux-style consoles: **⌘1…⌘9 / ⌘F1…** switch VTs. Default **`console-mode = login`** uses a getty banner and a full password prompt. **`shell`** matches Ghostty (`login -flp` → shell, shows **Last login:**).

## Requirements

- macOS 14+
- Xcode / Swift 6 toolchain
- Zig (same major as Ghostty; see [Ghostty build docs](https://ghostty.org/docs/install/build))
- Non-sandboxed build (`login` needs a non-sandbox environment)

## Build

```bash
./scripts/build-libghostty.sh   # pin + patches + libghostty-vt.a
swift build --disable-sandbox -c release
swift run --disable-sandbox -c release
# or
./scripts/run.sh
```

### Vendoring libghostty-vt

Ghostty is **not** committed as a full tree. The build script:

1. Reads **`Vendor/ghostty.rev`** (exact commit SHA)
2. Clones/fetches into gitignored `Vendor/ghostty/`
3. Applies **`patches/*.patch`** in sorted order (search C shim until upstream ~1.4.0)
4. Builds `libghostty-vt.a` and stamps inputs so rebuilds are skipped when unchanged

```bash
# after editing patches/ or bumping the pin:
./scripts/build-libghostty.sh
swift build --disable-sandbox -c release
```

Bump Ghostty:

```bash
# put the new SHA in Vendor/ghostty.rev, refresh patches if needed, then:
./scripts/build-libghostty.sh
```

## Terminfo

Bundled Ghostty terminfo under `Sources/Ghosvt/Resources/terminfo/`:

| Variable | Value |
|----------|--------|
| `TERM` | `xterm-ghostty` (fallback `xterm-256color`) |
| `TERMINFO` | bundle `Resources/terminfo` when present |
| `COLORTERM` | `truecolor` |
| `TERM_PROGRAM` | `ghosvt` |
| `TERM_PROGRAM_VERSION` | `0.1.0` |

Refresh from Ghostty.app:

```bash
./scripts/fetch-terminfo.sh
```

## Console modes

| `console-mode` | Behavior |
|----------------|----------|
| **`login`** (default) | Getty banner + scrubbed env + `/usr/bin/login -p` (password prompt) |
| **`shell`** | Ghostty-style `login -flp $USER` → login shell; shows `Last login: …`; no getty banner |

Alias: `getty` → `login`.

## Config

Ghostty-style file: **`~/.config/ghosvt/config`**  
(or `$XDG_CONFIG_HOME/ghosvt/config`). Missing file → defaults.

```
# ~/.config/ghosvt/config
vt-count = 6
font-size = 18
console-mode = login
# banner-hostname = my-host   # getty banner only; omit for system hostname
scrollback-limit = 50000000
scroll-to-bottom = keystroke, no-output
max-aspect = 3:2
copy-on-select = true
font-ligatures = true
search-position = bottom
embedded-browser = true
```

### Options

| Key | Default | Notes |
|-----|---------|--------|
| `vt-count` | `6` | 1…12 |
| `font-size` | `18` | Points |
| `console-mode` | `login` | `login` (alias `getty`) \| `shell` |
| `banner-hostname` | *(system)* | Getty banner host field when `console-mode = login`. Empty/omit → `gethostname` |
| `scrollback-limit` | `50000000` | Bytes (Ghostty `scrollback-limit` / `scrollback-limit-bytes`). `unlimited` or `0` (off) |
| `scrollback-limit-bytes` | — | Alias for `scrollback-limit` |
| `scroll-to-bottom` | `keystroke, no-output` | Comma list: `keystroke` / `no-keystroke` / `output` / `no-output` |
| `max-aspect` / `max-aspect-ratio` | `3:2` | Cap content width/height (`3:2`, `3/2`, or float). Wider screens letterbox |
| `copy-on-select` | `true` | Copy selection to pasteboard on mouse-up |
| `font-ligatures` / `ligatures` | `true` | OpenType liga/calt on shaped runs |
| `search-position` | `bottom` | Stolen search row: `top` or `bottom` |
| `embedded-browser` | `true` | Embed via ⌘B / ⌘-click. When `false`: ⌘B off; ⌘-click opens the system browser |
| `scroll-spring-k` | `120` | Overscroll spring stiffness |
| `scroll-spring-c` | `14` | Overscroll damping |
| `scroll-friction` | `6` | Coast friction |

Bools: `true` / `yes` / `on` / `1`.

## Keys

| Binding | Action |
|---------|--------|
| **⌘1…⌘9** | Switch to VT 1…9 |
| **⌘F1…⌘F*n*** | Switch to VT 1…*n* |
| **⌘← / ⌘→** | Previous / next VT |
| **⌘Page Up** | Smooth scroll up (older history); accelerates while held |
| **⌘Page Down** | Smooth scroll down (toward bottom); accelerates while held |
| **⌘C** | Copy selection |
| **⌘V** | Paste |
| **⌘F** | Search scrollback (steals bottom VT row: `/needle`; gold/peach hits) |
| **⌘G** / **⇧⌘G** | Next / previous match (while search open) |
| **Esc** / **⌘F** again | Close search (restores shell rows) |
| **⌘B** | Open or focus embedded browser (when `embedded-browser = true`) |
| **⌘+** / **⌘=** | Increase font size (1pt; Ghostty) |
| **⌘-** | Decrease font size (1pt; Ghostty) |
| **⌘0** | Reset font size to config (Ghostty; not VT 10) |
| **⌘Q** | Quit |
| **Shift+Enter** / **Alt+Enter** | Send LF (`\n`) — newline for apps like Grok Build |
| **Enter** | Send CR (`\r`) (next match while search field focused) |
| Wheel / trackpad | Scroll history (spring overscroll) |
| Mouse drag | Host selection (or app mouse when tracking; Shift forces host select) |

VT switch shows a brief **VT *n*** label in the **upper-right** of the content area.

## Display

- Fullscreen Metal host at launch
- Content capped by `max-aspect` (default 3:2); side bars clear to the live terminal / FS TUI background
- Adaptive-Sync: `present(afterMinimumDuration:)` within the screen’s refresh range when the panel reports VRR
- HiDPI: cell metrics and glyph atlas rebuild on `backingScaleFactor` change
- Multi-monitor / sleep: on screen change or wake, rebind refresh rate + metrics + resize all live VTs; pause drawing while displays/system sleep
- Cursor defaults: cell-foreground fill / cell-background text (OSC 12 can still set a fixed cursor color)

## Rendering & VT

- Dirty-aware grid rebuild, CoreText shaping (horizontal placement aligned with Ghostty), glyph atlas
- Embedded **JetBrains Mono** (+ Nerd Symbols cascade); SGR bold uses ExtraBold when available
- Ghostty-style sprites (blocks, box drawing, braille, powerline, etc.); DECTCEM cursor hide
- Selection invert with correct ink; copy-on-select default on
- Scrollback search via Ghostty **ScreenSearch** (temporary C shim until ~1.4.0); steals one shell row for a cell-style `/needle` HUD; gold / peach match paint
- PTY gather + parse threads (Ghostty-style ring / bridge policy) so bulk IO does not stall Metal

## Fonts

Refresh embedded fonts:

```bash
./scripts/fetch-fonts.sh
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build-libghostty.sh` | Pin Ghostty @ `Vendor/ghostty.rev`, apply `patches/`, build `libghostty-vt.a` |
| `scripts/run.sh` | Stamp-aware libghostty build + release run |
| `scripts/fetch-terminfo.sh` | Refresh bundled terminfo |
| `scripts/fetch-fonts.sh` | Refresh embedded fonts |

| Path | Purpose |
|------|---------|
| `Vendor/ghostty.rev` | Pinned Ghostty commit |
| `patches/*.patch` | Local libghostty-vt patches (search C shim) |
| `Vendor/ghostty/` | Working tree (gitignored) |

## License

ghosvt is **[MIT](LICENSE.md)**

Vendored **libghostty-vt** remains under the [Ghostty project license](https://github.com/ghostty-org/ghostty/blob/main/LICENSE).
