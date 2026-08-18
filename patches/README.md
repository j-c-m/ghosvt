# libghostty-vt patches

Applied in sorted order by `scripts/build-libghostty.sh` onto the commit in
`Vendor/ghostty.rev`.

| Patch | Purpose |
|-------|---------|
| `0001-libghostty-vt-search-c-shim.patch` | ScreenSearch C API (`ghostty_screen_search_*`) |
| `0002-libghostty-vt-row-collect.patch` | Packed row collect (`ghostty_render_state_row_cells_collect`) |

Collect is the first upstream candidate: it sits in the existing render
state C API, returns the same fg/bg as `row_cells_get`, and treats inverse
as a flag only. Search is also submission-shaped, but should go second.

## Refresh after a pin bump

`0002` is generated against pin + `0001` (not the clean pin).

```bash
cd Vendor/ghostty

# 0001: search only (header, C module, feature flag, vt.h include, exports)
git add include/ghostty/vt/search.h src/terminal/c/search.zig \
  include/ghostty/vt.h src/lib_vt.zig src/terminal/c/main.zig \
  src/terminal/build_options.zig
git diff --cached > ../../patches/0001-libghostty-vt-search-c-shim.patch
git commit -m tmp-search

# 0002: collect on top of 0001 (typedef, pack, tests, collect export)
git add include/ghostty/vt/render.h src/terminal/c/render.zig \
  src/lib_vt.zig src/terminal/c/main.zig
git diff --cached > ../../patches/0002-libghostty-vt-row-collect.patch
git reset --hard HEAD~1
```
