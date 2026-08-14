# libghostty-vt patches

Applied in sorted order by `scripts/build-libghostty.sh` onto the commit in
`Vendor/ghostty.rev`.

| Patch | Purpose |
|-------|---------|
| `0001-libghostty-vt-search-c-shim.patch` | Temporary C ABI for `ScreenSearch` until Ghostty ~1.4.0 |
| `0002-libghostty-vt-row-collect.patch` | One-call packed row collect (`ghostty_render_state_row_cells_collect`) |

## Refresh after a pin bump

```bash
# checkout clean pin, re-apply edits or cherry-pick, then:
cd Vendor/ghostty
git add -A include/ghostty/vt/search.h src/terminal/c/search.zig \
  include/ghostty/vt.h src/lib_vt.zig src/terminal/c/main.zig
git diff --cached > ../../patches/0001-libghostty-vt-search-c-shim.patch
git reset HEAD
```

`0002` is generated against pin + `0001` (not the clean pin). When upstream ships a row-collect C API, delete that patch and rebuild.
