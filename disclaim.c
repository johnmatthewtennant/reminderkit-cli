#include "disclaim.h"

#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t attrs, int disclaim);

extern const char reminderkit_info_plist_section_start __asm("section$start$__TEXT$__info_plist");
extern const char reminderkit_info_plist_section_end   __asm("section$end$__TEXT$__info_plist");

static const char *kReentryEnvVar = "REMINDERKIT_DISCLAIMED";
static const char *kBypassEnvVar = "REMINDERKIT_NO_DISCLAIM";

static volatile pid_t g_child_pid = 0;

static void forward_signal(int sig) {
    pid_t pid = g_child_pid;
    if (pid > 0) {
        kill(pid, sig);
    }
}

static void install_forwarders(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = forward_signal;
    sigemptyset(&sa.sa_mask);
    int signals[] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2 };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &sa, NULL);
    }
}

static const char *current_executable_path(void) {
    static char proc_path[PROC_PIDPATHINFO_MAXSIZE];
    int n = proc_pidpath(getpid(), proc_path, sizeof(proc_path));
    if (n > 0) {
        return proc_path;
    }

    static char dyld_path[PROC_PIDPATHINFO_MAXSIZE];
    uint32_t size = (uint32_t)sizeof(dyld_path);
    if (_NSGetExecutablePath(dyld_path, &size) == 0) {
        return dyld_path;
    }

    return NULL;
}

void reminderkit_disclaim_if_needed(int argc, char *argv[]) {
    (void)argc;

    if (getenv(kReentryEnvVar) != NULL) {
        unsetenv(kReentryEnvVar);
        return;
    }

    if (getenv(kBypassEnvVar) != NULL) {
        return;
    }

    if (setenv(kReentryEnvVar, "1", 1) != 0) {
        return;
    }

    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) {
        return;
    }
    if (responsibility_spawnattrs_setdisclaim(&attrs, 1) != 0) {
        posix_spawnattr_destroy(&attrs);
        return;
    }

    char **envp = *_NSGetEnviron();
    pid_t pid = 0;
    const char *spawn_path = current_executable_path();
    if (spawn_path == NULL) {
        spawn_path = argv[0];
    }
    int rc = posix_spawn(&pid, spawn_path, NULL, &attrs, argv, envp);
    posix_spawnattr_destroy(&attrs);

    if (rc != 0) {
        unsetenv(kReentryEnvVar);
        return;
    }

    g_child_pid = pid;
    install_forwarders();

    int status = 0;
    while (1) {
        pid_t w = waitpid(pid, &status, 0);
        if (w == -1) {
            if (errno == EINTR) {
                continue;
            }
            _exit(1);
        }
        break;
    }

    if (WIFEXITED(status)) {
        _exit(WEXITSTATUS(status));
    } else if (WIFSIGNALED(status)) {
        signal(WTERMSIG(status), SIG_DFL);
        raise(WTERMSIG(status));
        _exit(128 + WTERMSIG(status));
    }
    _exit(1);
}

typedef pid_t (*reminderkit_resp_pid_fn)(pid_t);

pid_t reminderkit_responsible_pid(void) {
    static reminderkit_resp_pid_fn fn = NULL;
    static int resolved = 0;
    if (!resolved) {
        fn = (reminderkit_resp_pid_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        resolved = 1;
    }
    if (!fn) return -1;
    return fn(getpid());
}

const void *reminderkit_embedded_info_plist_bytes(size_t *length) {
    size_t n = (size_t)(&reminderkit_info_plist_section_end - &reminderkit_info_plist_section_start);
    if (length) *length = n;
    if (n == 0) return NULL;
    return &reminderkit_info_plist_section_start;
}
