/*
 * diskm root launcher — stable Mach-O identity for macOS Full Disk Access.
 *
 * TCC grants FDA to an executable, not a script, and a LaunchDaemon does not
 * inherit the terminal's grant. Installed root-owned at
 * /usr/local/libexec/disk-magician/diskm and granted FDA once in System
 * Settings; children it spawns inherit that grant (bead disk_magician-4y6).
 *
 * Runs only the immutable scanner beside it, in isolated mode (-I ignores
 * PYTHON* env and user site), and refuses non-root callers so the grant
 * cannot be borrowed by an unprivileged process.
 */
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

#define PYTHON "/usr/bin/python3"
#define SCANNER "/usr/local/libexec/disk-magician/disk_frontier_scan.py"

extern char **environ;
static pid_t child;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    if (getuid() != 0 || geteuid() != 0) {
        fprintf(stderr, "diskm launcher: must run as root\n");
        return 77;
    }
    char **args = calloc((size_t)argc + 3, sizeof(char *));
    if (!args) return 70;
    args[0] = PYTHON;
    args[1] = "-I";
    args[2] = SCANNER;
    for (int i = 1; i < argc; i++) args[i + 2] = argv[i];

    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    int rc = posix_spawn(&child, PYTHON, NULL, NULL, args, environ);
    if (rc != 0) {
        fprintf(stderr, "diskm launcher: spawn %s failed (%d)\n", PYTHON, rc);
        return 71;
    }
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 71;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}
