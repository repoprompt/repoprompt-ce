#include "startup_termination_signal.h"

#include <errno.h>
#include <signal.h>
#include <string.h>

static volatile sig_atomic_t rpce_startup_sigterm_flag = 0;
static struct sigaction rpce_startup_sigterm_previous;
static int rpce_startup_sigterm_installed = 0;

static void rpce_startup_sigterm_record(int signal_number) {
    (void)signal_number;
    rpce_startup_sigterm_flag = 1;
}

int rpce_startup_sigterm_install(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = rpce_startup_sigterm_record;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    rpce_startup_sigterm_flag = 0;
    if (sigaction(SIGTERM, &action, &rpce_startup_sigterm_previous) != 0) return errno;
    rpce_startup_sigterm_installed = 1;
    return 0;
}

int rpce_startup_sigterm_requested(void) {
    return rpce_startup_sigterm_flag != 0;
}

int rpce_startup_sigterm_restore(void) {
    if (!rpce_startup_sigterm_installed) return 0;
    rpce_startup_sigterm_installed = 0;
    return sigaction(SIGTERM, &rpce_startup_sigterm_previous, NULL) == 0 ? 0 : errno;
}
