#ifndef REPO_WILDMATCH_WRAPPER_H
#define REPO_WILDMATCH_WRAPPER_H

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    char pattern[1024];
    bool is_negation;
    bool directory_only;
    bool absolute;
} repo_gitignore_pattern;

int repo_wildmatch(const char *pattern, const char *text, unsigned int flags);
int repo_gitignore_match_anchored(const char *pattern, const char *path);
int repo_gitignore_match_anywhere(const char *pattern, const char *path);
void repo_normalize_pattern(char *dest, const char *src, size_t dest_size);
bool repo_parse_gitignore_line(const char *line, repo_gitignore_pattern *result);

#endif
