/*
 * RepoPromptC.h
 *
 * Umbrella header for the RepoPromptC module. Every public header must be listed
 * here: an explicit umbrella header makes adding or removing a header an edit to a
 * tracked module input, so warm clang module caches are invalidated correctly.
 * (An umbrella *directory* does not invalidate a cached module when a new header
 * appears.)
 */

#ifndef REPO_PROMPT_C_H
#define REPO_PROMPT_C_H

#include "file_descriptor_path.h"
#include "path_search.h"
#include "repo_gitignore.h"
#include "repo_process_security.h"
#include "search_scoring.h"
#include "session_catalog_sqlite.h"
#include "startup_termination_signal.h"
#include "string_extensions_wrapper.h"
#include "wildmatch.h"

#endif /* REPO_PROMPT_C_H */
