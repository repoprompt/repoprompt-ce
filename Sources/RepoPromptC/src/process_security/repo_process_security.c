/*
 * repo_process_security.c
 */

#include "repo_process_security.h"

#include <sys/types.h>
#if defined(__linux__)
#include <sys/prctl.h>
#else
#include <sys/ptrace.h>

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
#endif

int repo_deny_debugger_attachment(void)
{
#if defined(__linux__)
    return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
#else
    return ptrace(PT_DENY_ATTACH, 0, 0, 0);
#endif
}
