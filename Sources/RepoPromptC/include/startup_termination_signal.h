#ifndef REPOPROMPT_STARTUP_TERMINATION_SIGNAL_H
#define REPOPROMPT_STARTUP_TERMINATION_SIGNAL_H

// Debug startup state preparation runs before AppKit and before the app's own
// SIGTERM router exists. While it runs, SIGTERM is recorded synchronously by an
// async-signal-safe handler (no callback latency, no lost delivery) so preparation
// can stop at a safe point; restoring reinstates the previous disposition.

// Installs the recording handler and clears any earlier request. Returns 0 or errno.
int rpce_startup_sigterm_install(void);

// Nonzero once SIGTERM was delivered since the last install.
int rpce_startup_sigterm_requested(void);

// Reinstates the disposition saved by install. Returns 0 or errno.
int rpce_startup_sigterm_restore(void);

#endif
