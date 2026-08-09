#include "pty_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

static int terminfo_has_xterm_ghostty(const char *dir) {
    if (!dir || !dir[0])
        return 0;
    char path[4096];
    int n = snprintf(path, sizeof(path), "%s/78/xterm-ghostty", dir);
    if (n <= 0 || (size_t)n >= sizeof(path))
        return 0;
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static void write_banner(int tty_index) {
    char ostype[64] = "Darwin";
    char machine[64] = "arm64";
    char host[256] = "localhost";

    size_t len = sizeof(ostype);
    (void)sysctlbyname("kern.ostype", ostype, &len, NULL, 0);
    len = sizeof(machine);
    (void)sysctlbyname("hw.machine", machine, &len, NULL, 0);
    if (gethostname(host, sizeof(host)) != 0) {
        strncpy(host, "localhost", sizeof(host) - 1);
    }
    host[sizeof(host) - 1] = '\0';

    dprintf(STDOUT_FILENO, "%s/%s (%s) (ttyv%d)\n\n", ostype, machine, host, tty_index);
    fsync(STDOUT_FILENO);
}

/** Drop inherited GUI/app environment so login -p only keeps what we set. */
static void scrub_environ(void) {
    /* macOS has no clearenv(3); unset each entry. environ is reshuffled by unsetenv. */
    extern char **environ;
    if (!environ)
        return;
    for (;;) {
        char *entry = environ[0];
        if (!entry)
            break;
        const char *eq = strchr(entry, '=');
        if (!eq) {
            /* Malformed; drop by setting empty environ best-effort. */
            unsetenv(entry);
            if (environ[0] == entry)
                break;
            continue;
        }
        size_t n = (size_t)(eq - entry);
        char name[256];
        if (n == 0 || n >= sizeof(name))
            break;
        memcpy(name, entry, n);
        name[n] = '\0';
        unsetenv(name);
    }
}

static void set_term_identity(const char *terminfo_dir) {
    setenv("COLORTERM", "truecolor", 1);
    setenv("TERM_PROGRAM", "ghosvt", 1);
    setenv("TERM_PROGRAM_VERSION", "0.1.0", 1);

    if (terminfo_has_xterm_ghostty(terminfo_dir)) {
        setenv("TERM", "xterm-ghostty", 1);
        setenv("TERMINFO", terminfo_dir, 1);
    } else {
        setenv("TERM", "xterm-256color", 1);
        dprintf(STDERR_FILENO,
                "ghosvt: xterm-ghostty terminfo not found; using xterm-256color\n");
    }
}

/**
 * Minimal environment for login -p: only terminal identity + terminfo.
 * login still adds HOME/SHELL/USER/PATH/etc. after authentication.
 */
static void setup_login_env(const char *terminfo_dir) {
    scrub_environ();
    set_term_identity(terminfo_dir);
}

/**
 * Keep the host user environment; only force terminal identity.
 * Used for console-mode = shell (no login(1)).
 */
static void setup_shell_env(const char *terminfo_dir) {
    set_term_identity(terminfo_dir);
}

static const char *resolve_shell(void) {
    const char *shell = getenv("SHELL");
    if (shell && shell[0])
        return shell;
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_shell && pw->pw_shell[0])
        return pw->pw_shell;
    return "/bin/zsh";
}

int ghosvt_pty_spawn(int tty_index, uint16_t cols, uint16_t rows,
                     uint32_t cell_width_px, uint32_t cell_height_px,
                     const char *terminfo_dir,
                     GhosvtConsoleMode console_mode,
                     pid_t *child_out) {
    if (!child_out) {
        return -1;
    }

    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = (unsigned short)(cols * cell_width_px),
        .ws_ypixel = (unsigned short)(rows * cell_height_px),
    };

    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &ws);
    if (child < 0) {
        return -1;
    }

    if (child == 0) {
        /* Copy path before scrubbing (and for setenv's own storage). */
        char terminfo_buf[4096];
        const char *ti = NULL;
        if (terminfo_dir && terminfo_dir[0]) {
            strncpy(terminfo_buf, terminfo_dir, sizeof(terminfo_buf) - 1);
            terminfo_buf[sizeof(terminfo_buf) - 1] = '\0';
            ti = terminfo_buf;
        }

        write_banner(tty_index);

        if (console_mode == GHOSVT_CONSOLE_SHELL) {
            setup_shell_env(ti);
            const char *shell = resolve_shell();
            /* Login shell so profile/rc load (typical terminal emulator). */
            execl(shell, shell, "-l", (char *)NULL);
            dprintf(STDERR_FILENO, "ghosvt: exec shell %s failed: %s\n", shell, strerror(errno));
            _exit(127);
        }

        setup_login_env(ti);
        /*
         * login -p: keep only the scrubbed env we just built (TERM/TERMINFO/…).
         * Without -p, macOS login drops TERMINFO even if it special-cases TERM.
         */
        execl("/usr/bin/login", "login", "-p", (char *)NULL);
        dprintf(STDERR_FILENO, "ghosvt: exec /usr/bin/login failed: %s\n", strerror(errno));
        _exit(127);
    }

    int flags = fcntl(master, F_GETFL);
    if (flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(master);
        return -1;
    }

    *child_out = child;
    return master;
}

int ghosvt_pty_set_winsize(int master_fd, uint16_t cols, uint16_t rows,
                           uint32_t cell_width_px, uint32_t cell_height_px) {
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = (unsigned short)(cols * cell_width_px),
        .ws_ypixel = (unsigned short)(rows * cell_height_px),
    };
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

ssize_t ghosvt_pty_write_all(int master_fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(master_fd, p, left);
        if (n > 0) {
            p += (size_t)n;
            left -= (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    return (ssize_t)(len - left);
}
