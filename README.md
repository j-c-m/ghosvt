# ghosvt

Fullscreen macOS multi-VT terminal on **libghostty-vt** + **Metal**.

Linux-style consoles: **⌘1…⌘9 / ⌘F1…** switch VTs. Default **`console-mode = shell`** matches Ghostty (`login -flp` → shell, shows **Last login:**). **`login`** mode uses a getty banner and a full password prompt.

## Requirements

- macOS 14+
- Xcode / Swift 6 toolchain
- Zig (same major as Ghostty; see [Ghostty build docs](https://ghostty.org/docs/install/build))
- Non-sandboxed build (`login` needs a non-sandbox environment)

## Build

```bash
# once: vendor ghostty (if missing)
git clone --depth 1 https://github.com/ghostty-org/ghostty.git Vendor/ghostty

./scripts/build-libghostty.sh
swift build --disable-sandbox -c release
swift run --disable-sandbox -c release
# or
./scripts/run.sh
```

Refresh libghostty-vt after updating `Vendor/ghostty`:

```bash
./scripts/build-libghostty.sh
swift build --disable-sandbox -c release
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
| **`shell`** (default) | Ghostty-style `login -flp $USER` → login shell; shows `Last login: …`; no getty banner |
| **`login`** | Getty banner + scrubbed env + `/usr/bin/login -p` (password prompt) |

Alias: `getty` → `login`.

## Config

Ghostty-style file: **`~/.config/ghosvt/config`**  
(or `$XDG_CONFIG_HOME/ghosvt/config`). Missing file → defaults.

```
# ~/.config/ghosvt/config
vt-count = 6
font-size = 20
console-mode = shell
scrollback-limit = 50000000
scroll-to-bottom = keystroke, no-output
max-aspect = 3:2
copy-on-select = true
font-ligatures = true
```

### Options

| Key | Default | Notes |
|-----|---------|--------|
| `vt-count` | `6` | 1…12 |
| `font-size` | `20` | Points |
| `console-mode` | `shell` | `shell` \| `login` (alias `getty`) |
| `scrollback-limit` | `50000000` | Bytes (Ghostty `scrollback-limit` / `scrollback-limit-bytes`). `unlimited` or `0` (off) |
| `scrollback-limit-bytes` | — | Alias for `scrollback-limit` |
| `scroll-to-bottom` | `keystroke, no-output` | Comma list: `keystroke` / `no-keystroke` / `output` / `no-output` |
| `max-aspect` / `max-aspect-ratio` | `3:2` | Cap content width/height (`3:2`, `3/2`, or float). Wider screens letterbox |
| `copy-on-select` | `true` | Copy selection to pasteboard on mouse-up |
| `font-ligatures` / `ligatures` | `true` | OpenType liga/calt on shaped runs |
| `scroll-spring-k` | `120` | Overscroll spring stiffness |
| `scroll-spring-c` | `14` | Overscroll damping |
| `scroll-friction` | `6` | Coast friction |

Bools: `true` / `yes` / `on` / `1`.

## Keys

| Binding | Action |
|---------|--------|
| **⌘1…⌘9** | Switch to VT 1…9 |
| **⌘0** | VT 10 (if `vt-count` ≥ 10) |
| **⌘F1…⌘F*n*** | Same |
| **⌘← / ⌘→** | Previous / next VT |
| **⌘Page Up** | Scroll one page up (older history; Ghostty) |
| **⌘Page Down** | Scroll one page down (toward bottom) |
| **⌘C** | Copy selection |
| **⌘V** | Paste |
| **⌘Q** | Quit |
| **Shift+Enter** / **Alt+Enter** | Send LF (`\n`) — newline for apps like Grok Build |
| **Enter** | Send CR (`\r`) |
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
- PTY gather + parse threads (Ghostty-style ring / bridge policy) so bulk IO does not stall Metal

## Fonts

Refresh embedded fonts:

```bash
./scripts/fetch-fonts.sh
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build-libghostty.sh` | Build `libghostty-vt.a` (ReleaseFast) |
| `scripts/run.sh` | Build release + run |
| `scripts/fetch-terminfo.sh` | Refresh bundled terminfo |
| `scripts/fetch-fonts.sh` | Refresh embedded fonts |

## License

App code: TBD. libghostty-vt: Ghostty project license.
