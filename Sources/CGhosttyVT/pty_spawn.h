#ifndef GHOSVT_PTY_SPAWN_H
#define GHOSVT_PTY_SPAWN_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Spawn a getty-style login on a new PTY.
 *
 * Child: banner + exec /usr/bin/login -p (preserves TERM/TERMINFO).
 * Parent: non-blocking master fd; child pid in *child_out.
 *
 * @param terminfo_dir Absolute path to a terminfo database dir containing
 *        78/xterm-ghostty (and optionally 67/ghostty). May be NULL to fall
 *        back to xterm-256color without TERMINFO override.
 * @return master fd (>=0) or -1 on error
 */
int ghosvt_pty_spawn_login(int tty_index, uint16_t cols, uint16_t rows,
                           uint32_t cell_width_px, uint32_t cell_height_px,
                           const char *terminfo_dir,
                           pid_t *child_out);

int ghosvt_pty_set_winsize(int master_fd, uint16_t cols, uint16_t rows,
                           uint32_t cell_width_px, uint32_t cell_height_px);

/** Best-effort write; returns bytes written (may be short on EAGAIN). */
ssize_t ghosvt_pty_write_all(int master_fd, const void *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* GHOSVT_PTY_SPAWN_H */
