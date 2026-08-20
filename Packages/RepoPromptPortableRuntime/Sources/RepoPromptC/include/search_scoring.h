/*
 * search_scoring.h
 * 
 * Header file for high-performance search scoring functions
 */

#ifndef SEARCH_SCORING_H
#define SEARCH_SCORING_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* File information structure for batch processing */
struct repo_file_info {
    const char *name;
    const char *path;
    const char *name_lower;  /* Pre-lowercased filename for performance */
    const char *path_lower;  /* Pre-lowercased path for performance */
};

/* Zero-copy batch buffer for optimal performance
 * Contains all strings in a single contiguous buffer with offsets */
struct repo_batch_buffer {
    char *data;              /* Contiguous UTF-8 buffer containing all strings */
    size_t data_size;        /* Total size of the data buffer */
    size_t *offsets;         /* Array of offsets into data buffer (4 per file) */
    size_t file_count;       /* Number of files in the batch */
};

/* Create a zero-copy batch buffer from arrays of strings
 * The caller must call repo_free_batch_buffer() when done */
struct repo_batch_buffer* repo_create_batch_buffer(
    const char **names, const char **paths,
    const char **names_lower, const char **paths_lower,
    size_t file_count);

/* Free a batch buffer created by repo_create_batch_buffer */
void repo_free_batch_buffer(struct repo_batch_buffer *buffer);

/* Zero-copy batch scoring function
 * Uses the batch buffer to avoid per-file allocations */
void repo_score_matches_batch_zerocopy(
    const struct repo_batch_buffer *buffer,
    const char *query, const char *query_lower,
    bool has_slash, bool is_wildcard,
    double fuzzy_threshold, int *scores);

/* Opaque type for compiled wildcard patterns */
typedef struct repo_wildcard_pattern repo_wildcard_pattern;

/* Compile a wildcard pattern for repeated use
 * Returns NULL on error. Caller must free with repo_free_wildcard_pattern() */
repo_wildcard_pattern* repo_compile_wildcard(const char *pattern);

/* Free a compiled wildcard pattern */
void repo_free_wildcard_pattern(repo_wildcard_pattern *compiled);

/* Score a match using a pre-compiled wildcard pattern
 * More efficient than repo_score_match when using the same pattern repeatedly */
int repo_score_match_compiled(
    const char *file_name, const char *file_path,
    const char *file_name_lower, const char *file_path_lower,
    const char *query, const char *query_lower,
    bool has_slash, repo_wildcard_pattern *compiled_pattern,
    double fuzzy_threshold);

/* Batch scoring with pre-compiled wildcard pattern */
void repo_score_matches_batch_compiled(
    const struct repo_file_info *files, size_t file_count,
    const char *query, const char *query_lower,
    bool has_slash, repo_wildcard_pattern *compiled_pattern,
    double fuzzy_threshold, int *scores);

/* Multi-threaded batch scoring configuration */
struct repo_mt_config {
    int thread_count;        /* Number of threads to use (0 = auto-detect) */
    size_t min_batch_size;   /* Minimum files per thread (default: 100) */
};

/* Multi-threaded batch scoring function
 * Automatically splits work across multiple threads for better performance
 * The scores array must be pre-allocated and thread-safe (no overlapping regions) */
void repo_score_matches_batch_mt(
    const struct repo_file_info *files, size_t file_count,
    const char *query, const char *query_lower,
    bool has_slash, bool is_wildcard,
    double fuzzy_threshold, int *scores,
    const struct repo_mt_config *config);

/* Multi-threaded zero-copy batch scoring */
void repo_score_matches_batch_zerocopy_mt(
    const struct repo_batch_buffer *buffer,
    const char *query, const char *query_lower,
    bool has_slash, bool is_wildcard,
    double fuzzy_threshold, int *scores,
    const struct repo_mt_config *config);

/* Multi-threaded scoring with pre-compiled patterns */
void repo_score_matches_batch_compiled_mt(
    const struct repo_file_info *files, size_t file_count,
    const char *query, const char *query_lower,
    bool has_slash, repo_wildcard_pattern *compiled_pattern,
    double fuzzy_threshold, int *scores,
    const struct repo_mt_config *config);

/* Score a single file match based on hierarchical relevance
 * Returns a score from 0-1000, where 0 means no match
 * 
 * Scoring hierarchy:
 * - 1000: Exact filename match
 * - 950:  Exact full path match
 * - 900:  Filename starts with query
 * - 875:  Path starts with query (slash queries only)
 * - 850:  Path component starts with query
 * - 750:  Filename contains query
 * - 700:  Path contains query (slash queries only)
 * - 650:  Wildcard pattern match
 * - 500:  Fuzzy match on filename
 * - 450:  Fuzzy match on path component
 * - 0:    No match
 * 
 * The name_lower and path_lower parameters should contain pre-lowercased versions
 * of file_name and file_path. If NULL, the function will lowercase internally.
 * query_lower should be a pre-lowercased version of query.
 */
int repo_score_match(const char *file_name, const char *file_path,
                     const char *file_name_lower, const char *file_path_lower,
                     const char *query, const char *query_lower,
                     bool has_slash, bool is_wildcard,
                     double fuzzy_threshold);

/* Batch scoring function for better performance
 * Scores an array of files and returns results in the scores array
 * The scores array must be pre-allocated with at least file_count elements
 * 
 * Uses pre-lowercased strings from repo_file_info if available (non-NULL),
 * otherwise falls back to lowercasing internally.
 */
void repo_score_matches_batch(const struct repo_file_info *files, size_t file_count,
                             const char *query, const char *query_lower,
                             bool has_slash, bool is_wildcard,
                             double fuzzy_threshold, int *scores);

#ifdef __cplusplus
}
#endif

#endif /* SEARCH_SCORING_H */