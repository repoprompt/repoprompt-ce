#ifndef path_search_h
#define path_search_h

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Path search index structure
typedef struct path_search_index {
    char** forward_paths;      // Sorted array of paths
    char** reversed_paths;     // Sorted array of reversed paths
    char** original_paths;     // Original unsorted paths
    size_t* forward_indices;   // Maps forward index to original index
    size_t* reversed_indices;  // Maps reversed index to original index
    size_t count;              // Number of paths
    size_t capacity;           // Allocated capacity
    size_t maximum_path_length;// Largest original path, excluding NUL
} path_search_index_t;

typedef struct path_search_cancellation path_search_cancellation_t;

typedef struct path_search_work_stats {
    size_t examined_count;
    size_t matched_count;
    size_t heap_peak_count;
    size_t heap_comparison_count;
    size_t scratch_bytes;
    bool cancelled;
} path_search_work_stats_t;

// Pattern decomposition result
typedef struct pattern_parts {
    char* prefix;              // Longest literal prefix
    char* suffix;              // Longest literal suffix
    char* regex_pattern;       // Full regex pattern
    bool is_wildcard;          // Contains wildcards
} pattern_parts_t;

// Search result. `scores` are globally comparable; higher values sort first.
// The current matcher is boolean, so every accepted match has score 1 and preserves
// the historical lexical ordering through `tie_break_keys`. Tie-break strings are
// borrowed from the immutable index and remain valid while the index is retained.
typedef struct search_result {
    size_t* indices;               // Array of matching original indices
    int32_t* scores;               // Comparable match scores
    const char** tie_break_keys;   // Deterministic lexical ordering keys
    size_t count;                  // Number of matches
    size_t capacity;               // Allocated capacity
} search_result_t;

// Index creation and destruction
path_search_index_t* path_search_create(const char** paths, size_t count);
void path_search_destroy(path_search_index_t* index);

// Pattern decomposition
pattern_parts_t* pattern_decompose(const char* pattern);
void pattern_parts_destroy(pattern_parts_t* parts);

// Binary search functions
size_t path_search_lower_bound(const char** array, size_t count, const char* prefix);
size_t path_search_upper_bound(const char** array, size_t count, const char* prefix);

// Main search function
search_result_t* path_search_find(
    const path_search_index_t* index,
    const char* pattern,
    size_t limit
);

// Query a root-neutral relative index as if every key were
// `display_prefix + relative_path + "\n" + absolute_prefix + relative_path`.
// Returned indices are relative-base ordinals; tie-break keys are reconstructed
// by the Swift projection and are therefore omitted from this result.
search_result_t* path_search_projected_find(
    const path_search_index_t* relative_index,
    const char* pattern,
    const char* display_prefix,
    const char* absolute_prefix,
    size_t limit
);
search_result_t* path_search_projected_find_cancellable(
    const path_search_index_t* relative_index,
    const char* pattern,
    const char* display_prefix,
    const char* absolute_prefix,
    size_t limit,
    const path_search_cancellation_t* cancellation,
    path_search_work_stats_t* stats
);
path_search_cancellation_t* path_search_cancellation_create(void);
void path_search_cancellation_cancel(path_search_cancellation_t* cancellation);
void path_search_cancellation_destroy(path_search_cancellation_t* cancellation);
void search_result_destroy(search_result_t* result);

// Helper functions
char* path_reverse(const char* path);
int path_compare(const void* a, const void* b);
bool path_matches_regex(const char* path, const char* regex_pattern);

#ifdef __cplusplus
}
#endif

#endif /* path_search_h */
