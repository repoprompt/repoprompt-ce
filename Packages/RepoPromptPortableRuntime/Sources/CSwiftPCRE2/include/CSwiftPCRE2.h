#ifndef C_SWIFT_PCRE2_H
#define C_SWIFT_PCRE2_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RPPCRE2Code RPPCRE2Code;
typedef struct RPPCRE2MatchData RPPCRE2MatchData;
typedef struct RPPCRE2MatchContext RPPCRE2MatchContext;

RPPCRE2Code *rp_pcre2_compile_8(const uint8_t *pattern, size_t length, uint32_t options, int *error_code, size_t *error_offset);
void rp_pcre2_code_free_8(RPPCRE2Code *code);
RPPCRE2MatchData *rp_pcre2_match_data_create_from_pattern_8(const RPPCRE2Code *code);
void rp_pcre2_match_data_free_8(RPPCRE2MatchData *match_data);
RPPCRE2MatchContext *rp_pcre2_match_context_create_8(void);
void rp_pcre2_match_context_free_8(RPPCRE2MatchContext *match_context);
int rp_pcre2_set_match_limit_8(RPPCRE2MatchContext *match_context, uint32_t limit);
int rp_pcre2_set_depth_limit_8(RPPCRE2MatchContext *match_context, uint32_t limit);
int rp_pcre2_set_heap_limit_8(RPPCRE2MatchContext *match_context, uint32_t limit);
int rp_pcre2_match_8(const RPPCRE2Code *code, const uint8_t *subject, size_t length, size_t start_offset, uint32_t options, RPPCRE2MatchData *match_data);
int rp_pcre2_match_with_context_8(const RPPCRE2Code *code, const uint8_t *subject, size_t length, size_t start_offset, uint32_t options, RPPCRE2MatchData *match_data, RPPCRE2MatchContext *match_context);
int rp_pcre2_jit_match_with_context_8(const RPPCRE2Code *code, const uint8_t *subject, size_t length, size_t start_offset, uint32_t options, RPPCRE2MatchData *match_data, RPPCRE2MatchContext *match_context);
uint32_t rp_pcre2_get_ovector_count_8(RPPCRE2MatchData *match_data);
size_t *rp_pcre2_get_ovector_pointer_8(RPPCRE2MatchData *match_data);
int rp_pcre2_get_error_message_8(int error_code, uint8_t *buffer, size_t buffer_length);
int rp_pcre2_ascii_whole_word_line_scan_8(const uint8_t *subject, size_t length, const uint8_t *needle, size_t needle_length, int case_insensitive, size_t *line_numbers_out, size_t line_numbers_capacity, size_t *collected_count_out, size_t *line_count_out, int *non_ascii_out);
int rp_pcre2_ascii_whole_word_line_count_8(const uint8_t *subject, size_t length, const uint8_t *needle, size_t needle_length, int case_insensitive, size_t *line_count_out, int *non_ascii_out);
int rp_pcre2_ascii_declaration_line_scan_8(const uint8_t *subject, size_t length, int case_insensitive, size_t *line_numbers_out, size_t line_numbers_capacity, size_t *collected_count_out, size_t *line_count_out, int *fallback_required_out);
int rp_pcre2_ascii_marker_line_scan_8(const uint8_t *subject, size_t length, const uint8_t *marker, size_t marker_length, uint32_t digit_count, const uint8_t *required_prefix, size_t required_prefix_length, int case_insensitive, size_t *line_numbers_out, size_t line_numbers_capacity, size_t *collected_count_out, size_t *line_count_out, int *non_ascii_out);
int rp_pcre2_ascii_marker_line_range_scan_8(const uint8_t *subject, size_t length, const uint8_t *marker, size_t marker_length, uint32_t digit_count, const uint8_t *required_prefix, size_t required_prefix_length, int case_insensitive, size_t *line_numbers_out, size_t *line_starts_out, size_t *line_ends_out, size_t line_capacity, size_t *collected_count_out, size_t *line_count_out, int *non_ascii_out);
int rp_pcre2_config_jit_8(void);
int rp_pcre2_jit_compile_8(RPPCRE2Code *code, uint32_t options);
int rp_pcre2_jit_size_8(const RPPCRE2Code *code, size_t *size_out);

uint32_t rp_pcre2_option_utf_8(void);
uint32_t rp_pcre2_option_ucp_8(void);
uint32_t rp_pcre2_option_caseless_8(void);
uint32_t rp_pcre2_option_multiline_8(void);
uint32_t rp_pcre2_option_dotall_8(void);
uint32_t rp_pcre2_option_no_utf_check_8(void);
uint32_t rp_pcre2_option_notbol_8(void);
uint32_t rp_pcre2_option_noteol_8(void);
uint32_t rp_pcre2_jit_complete_8(void);
int rp_pcre2_error_nomatch_8(void);
int rp_pcre2_error_jit_unsupported_8(void);
int rp_pcre2_error_jit_badoption_8(void);
int rp_pcre2_error_matchlimit_8(void);
int rp_pcre2_error_depthlimit_8(void);
int rp_pcre2_error_heaplimit_8(void);
int rp_pcre2_error_jit_stacklimit_8(void);
size_t rp_pcre2_unset_8(void);

#ifdef __cplusplus
}
#endif

#endif
