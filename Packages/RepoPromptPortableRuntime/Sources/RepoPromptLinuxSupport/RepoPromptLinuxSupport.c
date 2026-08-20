#include "RepoPromptLinuxSupport.h"

#include <errno.h>
#include <sys/wait.h>

#if defined(__linux__)
#include <sys/prctl.h>
#endif

int rp_enable_child_subreaper(void) {
#if defined(__linux__)
    return prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
#else
    return 0;
#endif
}

pid_t rp_waitpid_nohang(pid_t pid, int *status) {
    return waitpid(pid, status, WNOHANG);
}
