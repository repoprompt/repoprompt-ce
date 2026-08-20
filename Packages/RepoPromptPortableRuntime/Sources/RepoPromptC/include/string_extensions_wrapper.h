/*
 * string_extensions_wrapper.h
 * 
 * Header file for high-performance C implementations of string manipulation functions
 */

#ifndef STRING_EXTENSIONS_WRAPPER_H
#define STRING_EXTENSIONS_WRAPPER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Levenshtein distance calculation with optional cap
 * Returns actual distance if <= maxDist, or maxDist + 1 if greater
 * Pass maxDist = -1 for uncapped calculation
 */
int repo_levenshtein_distance(const char *a, const char *b, int maxDist);

/* Sørensen–Dice coefficient on character bigrams
 * Returns value between 0.0 and 1.0
 */
double repo_dice_coefficient(const char *a, const char *b);

/* Finds the longest common subsequence between two strings
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_longest_common_subsequence(const char *a, const char *b);

/* Calculates similarity score based on algorithm selection
 * For strings <= 64 chars: Uses Levenshtein distance
 * For longer strings: Uses Dice coefficient
 */
double repo_similarity_score(const char *a, const char *b);

/* Encodes indentation as <sN> or <tN> format
 * type: 's' for spaces, 't' for tabs
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_encode_indentation(const char *line, char type);

/* Decodes indentation from <sN> or <tN> format
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_decode_indentation(const char *encoded);

/* Decodes common HTML entities
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_decode_html_entities(const char *html);

/* Condenses all whitespace runs to single spaces
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_condense_whitespace(const char *str);

/* 64-bit FNV-1a hash function */
uint64_t repo_fnv1a64(const char *str);

/* Escapes backslash, quote, newline, carriage return and tab
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_escape_string(const char *src);

/* Reverses repo_escape_string()
 * Converts sequences like \\n to newline, \\\" to quote, etc.
 * Returns dynamically allocated string that must be freed by caller
 */
char* repo_unescape_string(const char *src);

/* Result structure for split content operation */
struct repo_split_result {
    char **lines;
    size_t line_count;
    char *detected_ending;
};

/* Splits content by line endings while preserving the line content
 * Detects the line ending type used in the content
 * The caller must call repo_free_split_result() when done
 */
struct repo_split_result* repo_split_content_preserving_endings(const char *content);

/* Frees the memory allocated by repo_split_content_preserving_endings */
void repo_free_split_result(struct repo_split_result *result);

/* Result structure for split with line endings */
struct repo_line_ending_pair {
	char *line;
	char *ending;
};

struct repo_split_with_endings_result {
	struct repo_line_ending_pair *pairs;
	size_t count;
};

struct repo_split_with_endings_result* repo_split_content_preserving_all_endings(const char *content);
void repo_free_split_with_endings_result(struct repo_split_with_endings_result *result);

/* Fuzzy space matching - spaces in pattern match any amount of whitespace in text
 * Returns 1 if match found, 0 otherwise
 */
int repo_fuzzy_space_match(const char *pattern, const char *text, int case_insensitive);

/* Generates a canonical key for string comparison in diff generation
 * Applies normalization pipeline: HTML decode, lowercase, whitespace collapse,
 * qualifier stripping, separator collapse, length capping, delimiter stripping
 * Returns dynamically allocated string that must be freed by caller, or NULL if empty
 */
char* repo_canonical_key(const char *raw);

/* Finds the best dice coefficient match for a pattern among multiple candidates
 * Returns the index of the best match, or -1 if no match exceeds threshold
 * If best_score is not NULL, it will be set to the score of the best match
 */
int repo_bulk_dice_best_match(const char *pattern, const char **candidates, 
                             size_t count, double threshold, double *best_score);

/* ─────────────────────────────────────────────────────────────────────────────
 * Chat Content Parser Utilities
 * ───────────────────────────────────────────────────────────────────────────── */

/* Removes outer triple-backtick fences if present (with or without language spec)
 * Also handles partial code blocks by removing opening backticks when no closing exist
 * Returns true if successful, false if buffer too small
 */
bool repo_remove_outer_backticks(char *dest, const char *src, size_t dest_size);

/* Trims common leading whitespace from an array of lines
 * Note: This modifies the strings in-place. The lines array should contain
 * modifiable strings (e.g., allocated with strdup).
 * Returns true if successful
 */
bool repo_trim_leading_whitespace(char **lines, size_t line_count);

/* Decodes HTML entities, normalizes indentation to spaces, trims common leading
 * whitespace across non-empty lines, and preserves detected line endings.
 * Returns dynamically allocated string that must be freed by caller, or NULL on failure.
 */
char* repo_trim_common_leading_whitespace_preserving_endings(const char *content);

/* Extracts description content from XML-like tags
 * Looks for <description>content</description> and extracts the content
 * Returns true if successful (even if no description found - returns empty string)
 */
bool repo_extract_description(char *dest, const char *src, size_t dest_size);

/* Extracts complexity value from XML-like tags
 * Looks for <complexity>number</complexity> and extracts the integer
 * Returns the complexity value, or -1 if not found or invalid
 */
int repo_extract_complexity(const char *src);

#ifdef __cplusplus
}
#endif

#endif /* STRING_EXTENSIONS_WRAPPER_H */
