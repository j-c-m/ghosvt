# libghostty-vt patches

Applied in sorted order by `scripts/build-libghostty.sh` onto the commit in
`Vendor/ghostty.rev`.

| Patch | Purpose |
|-------|---------|
| `0001-libghostty-vt-search-c-shim.patch` | ScreenSearch C API (`ghostty_screen_search_*`) |
| `0002-libghostty-vt-row-cells-packed.patch` | Packed row cells (`GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_PACKED`) |

Packed cells is the first upstream candidate: it sits in the existing render
state C API (`row_get`), returns the same fg/bg as `row_cells_get`, and treats
inverse as a flag only. Search is also submission-shaped, but should go second.

`0001` and `0002` do not share files. Either can be regenerated against the
clean pin.

## Refresh after a pin bump

```bash
cd Vendor/ghostty

# 0001: search only (header, C module, feature flag, vt.h include, exports)
git add include/ghostty/vt/search.h src/terminal/c/search.zig \
  include/ghostty/vt.h src/lib_vt.zig src/terminal/c/main.zig \
  src/terminal/build_options.zig
git diff --cached > ../../patches/0001-libghostty-vt-search-c-shim.patch
git restore --staged --worktree .

# 0002: packed cells (typedef, row_get key, pack, tests)
git add include/ghostty/vt/render.h src/terminal/c/render.zig \
  src/terminal/c/types.zig
git diff --cached > ../../patches/0002-libghostty-vt-row-cells-packed.patch
git restore --staged --worktree .
```
