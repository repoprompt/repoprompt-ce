/*
 * repo_gitignore.h
 *
 * Gitignore-specific matching built on the bundled wildmatch implementation
 * (see repo_wildmatch_wrapper.c). Exposed through the RepoPromptC module so Swift
 * callers import it explicitly instead of relying on an app bridging header.
 */

#ifndef REPO_GITIGNORE_H
#define REPO_GITIGNORE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Gitignore-aware wildmatch for anchored and unanchored patterns. */
int repo_gitignore_match_anchored(const char *pattern, const char *path);
int repo_gitignore_match_anywhere(const char *pattern, const char *path);

/* Normalize a gitignore pattern into dest (always NUL-terminated). */
void repo_normalize_pattern(char *dest, const char *src, size_t dest_size);

/* Parsed gitignore line. */
typedef struct {
    char pattern[1024];
    bool is_negation;
    bool directory_only;
    bool absolute;
} repo_gitignore_pattern;

/* Parse one gitignore line; returns false for blank lines and comments. */
bool repo_parse_gitignore_line(const char *line, repo_gitignore_pattern *result);

#ifdef __cplusplus
}
#endif

#endif /* REPO_GITIGNORE_H */
