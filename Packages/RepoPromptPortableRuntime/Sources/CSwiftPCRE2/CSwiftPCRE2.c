#include "CSwiftPCRE2.h"
#include <string.h>

#ifndef PCRE2_CODE_UNIT_WIDTH
#define PCRE2_CODE_UNIT_WIDTH 8
#endif
#include "pcre2.h"

RPPCRE2Code *rp_pcre2_compile_8(const uint8_t *pattern, size_t length, uint32_t options, int *error_code, size_t *error_offset) {
	PCRE2_SIZE local_offset = 0;
	pcre2_code *code = pcre2_compile((PCRE2_SPTR)pattern, (PCRE2_SIZE)length, options, error_code, &local_offset, NULL);
	if (error_offset != NULL) {
		*error_offset = (size_t)local_offset;
	}
	return (RPPCRE2Code *)code;
}

void rp_pcre2_code_free_8(RPPCRE2Code *code) {
	pcre2_code_free((pcre2_code *)code);
}

RPPCRE2MatchData *rp_pcre2_match_data_create_from_pattern_8(const RPPCRE2Code *code) {
	return (RPPCRE2MatchData *)pcre2_match_data_create_from_pattern((const pcre2_code *)code, NULL);
}

void rp_pcre2_match_data_free_8(RPPCRE2MatchData *match_data) {
	pcre2_match_data_free((pcre2_match_data *)match_data);
}

RPPCRE2MatchContext *rp_pcre2_match_context_create_8(void) {
	return (RPPCRE2MatchContext *)pcre2_match_context_create(NULL);
}

void rp_pcre2_match_context_free_8(RPPCRE2MatchContext *match_context) {
	pcre2_match_context_free((pcre2_match_context *)match_context);
}

int rp_pcre2_set_match_limit_8(RPPCRE2MatchContext *match_context, uint32_t limit) {
	return pcre2_set_match_limit((pcre2_match_context *)match_context, limit);
}

int rp_pcre2_set_depth_limit_8(RPPCRE2MatchContext *match_context, uint32_t limit) {
	return pcre2_set_depth_limit((pcre2_match_context *)match_context, limit);
}

int rp_pcre2_set_heap_limit_8(RPPCRE2MatchContext *match_context, uint32_t limit) {
	return pcre2_set_heap_limit((pcre2_match_context *)match_context, limit);
}

int rp_pcre2_match_8(const RPPCRE2Code *code, const uint8_t *subject, size_t length, size_t start_offset, uint32_t options, RPPCRE2MatchData *match_data) {
	return rp_pcre2_match_with_context_8(code, subject, length, start_offset, options, match_data, NULL);
}

int rp_pcre2_match_with_context_8(const RPPCRE2Code *code, const uint8_t *subject, size_t length, size_t start_offset, uint32_t options, RPPCRE2MatchData *match_data, RPPCRE2MatchContext *match_context) {
	return pcre2_match((const pcre2_code *)code, (PCRE2_SPTR)subject, (PCRE2_SIZE)length, (PCRE2_SIZE)start_offset, options, (pcre2_match_data *)match_data, (pcre2_match_context *)match_context);
}

int rp_pcre2_jit_match_with_context_8(const RPPCRE2Code *code, const uint8_t *subject, size_t length, size_t start_offset, uint32_t options, RPPCRE2MatchData *match_data, RPPCRE2MatchContext *match_context) {
	return pcre2_jit_match((const pcre2_code *)code, (PCRE2_SPTR)subject, (PCRE2_SIZE)length, (PCRE2_SIZE)start_offset, options, (pcre2_match_data *)match_data, (pcre2_match_context *)match_context);
}

uint32_t rp_pcre2_get_ovector_count_8(RPPCRE2MatchData *match_data) {
	return pcre2_get_ovector_count((pcre2_match_data *)match_data);
}

size_t *rp_pcre2_get_ovector_pointer_8(RPPCRE2MatchData *match_data) {
	return (size_t *)pcre2_get_ovector_pointer((pcre2_match_data *)match_data);
}

int rp_pcre2_get_error_message_8(int error_code, uint8_t *buffer, size_t buffer_length) {
	return pcre2_get_error_message(error_code, (PCRE2_UCHAR *)buffer, (PCRE2_SIZE)buffer_length);
}

static int rp_ascii_is_word(uint8_t byte) {
	return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '_';
}

static int rp_ascii_is_horizontal_whitespace(uint8_t byte) {
	return byte == 0x09 || byte == 0x0B || byte == 0x0C || byte == 0x20;
}

static uint8_t rp_ascii_lower(uint8_t byte) {
	return (byte >= 'A' && byte <= 'Z') ? (uint8_t)(byte + 32) : byte;
}

static int rp_ascii_equal(uint8_t haystack, uint8_t needle, int case_insensitive) {
	return (case_insensitive ? rp_ascii_lower(haystack) : haystack) == needle;
}

static int rp_ascii_word_line_contains(const uint8_t *line, size_t length, const uint8_t *needle, size_t needle_length, int case_insensitive) {
	if (needle_length == 0 || length < needle_length) return 0;

	if (!case_insensitive) {
		const uint8_t *cursor = line;
		const uint8_t *end = line + length;
		while ((size_t)(end - cursor) >= needle_length) {
			const uint8_t *hit = (const uint8_t *)memchr(cursor, needle[0], (size_t)(end - cursor));
			if (hit == NULL || (size_t)(end - hit) < needle_length) return 0;
			if (memcmp(hit, needle, needle_length) == 0) {
				int previous_is_word = hit > line && rp_ascii_is_word(*(hit - 1));
				const uint8_t *next = hit + needle_length;
				int next_is_word = next < end && rp_ascii_is_word(*next);
				if (!previous_is_word && !next_is_word) return 1;
			}
			cursor = hit + 1;
		}
		return 0;
	}

	uint8_t first = needle[0];
	for (size_t index = 0; index + needle_length <= length; index++) {
		if (rp_ascii_lower(line[index]) != first) continue;
		int matched = 1;
		for (size_t offset = 1; offset < needle_length; offset++) {
			if (rp_ascii_lower(line[index + offset]) != needle[offset]) {
				matched = 0;
				break;
			}
		}
		if (!matched) continue;
		int previous_is_word = index > 0 && rp_ascii_is_word(line[index - 1]);
		size_t next = index + needle_length;
		int next_is_word = next < length && rp_ascii_is_word(line[next]);
		if (!previous_is_word && !next_is_word) return 1;
	}
	return 0;
}

int rp_pcre2_ascii_whole_word_line_scan_8(const uint8_t *subject, size_t length, const uint8_t *needle, size_t needle_length, int case_insensitive, size_t *line_numbers_out, size_t line_numbers_capacity, size_t *collected_count_out, size_t *line_count_out, int *non_ascii_out) {
	if (collected_count_out != NULL) *collected_count_out = 0;
	if (line_count_out != NULL) *line_count_out = 0;
	if (non_ascii_out != NULL) *non_ascii_out = 0;
	if (subject == NULL || needle == NULL || needle_length == 0) return -1;

	size_t line_count = 0;
	size_t collected_count = 0;
	size_t line_number = 0;
	size_t index = 0;

	while (index < length) {
		size_t line_start = index;
		size_t line_end = index;
		while (line_end < length) {
			uint8_t byte = subject[line_end];
			if (byte >= 0x80) {
				if (non_ascii_out != NULL) *non_ascii_out = 1;
				return 0;
			}
			if (byte == '\n' || byte == '\r') break;
			line_end++;
		}

		if (rp_ascii_word_line_contains(subject + line_start, line_end - line_start, needle, needle_length, case_insensitive)) {
			if (line_numbers_out != NULL && collected_count < line_numbers_capacity) {
				line_numbers_out[collected_count] = line_number;
				collected_count++;
			}
			line_count++;
		}

		if (line_end >= length) break;
		uint8_t delimiter = subject[line_end];
		index = line_end + 1;
		if (delimiter == '\r' && index < length && subject[index] == '\n') index++;
		line_number++;
	}

	if (collected_count_out != NULL) *collected_count_out = collected_count;
	if (line_count_out != NULL) *line_count_out = line_count;
	return 0;
}

int rp_pcre2_ascii_whole_word_line_count_8(const uint8_t *subject, size_t length, const uint8_t *needle, size_t needle_length, int case_insensitive, size_t *line_count_out, int *non_ascii_out) {
	return rp_pcre2_ascii_whole_word_line_scan_8(subject, length, needle, needle_length, case_insensitive, NULL, 0, NULL, line_count_out, non_ascii_out);
}

static int rp_declaration_consume_word(const uint8_t *line, size_t length, size_t *index, const char *word, int case_insensitive, int *fallback_required) {
	size_t start = *index;
	for (size_t offset = 0; word[offset] != '\0'; offset++) {
		if (*index >= length) {
			*index = start;
			return 0;
		}
		uint8_t hay = line[*index];
		if (hay >= 0x80) {
			*fallback_required = 1;
			*index = start;
			return 0;
		}
		if (!rp_ascii_equal(hay, (uint8_t)word[offset], case_insensitive)) {
			*index = start;
			return 0;
		}
		(*index)++;
	}
	return 1;
}

static int rp_declaration_line_matches(const uint8_t *line, size_t length, int case_insensitive, int *fallback_required) {
	size_t index = 0;
	while (index < length) {
		uint8_t byte = line[index];
		if (byte >= 0x80) {
			*fallback_required = 1;
			return 0;
		}
		if (!rp_ascii_is_horizontal_whitespace(byte)) break;
		index++;
	}

	size_t saved = index;
	if (rp_declaration_consume_word(line, length, &index, "final", case_insensitive, fallback_required)) {
		if (index >= length) return 0;
		uint8_t byte = line[index];
		if (byte >= 0x80) {
			*fallback_required = 1;
			return 0;
		}
		if (!rp_ascii_is_horizontal_whitespace(byte)) return 0;
		do {
			index++;
			if (index >= length) return 0;
			byte = line[index];
			if (byte >= 0x80) {
				*fallback_required = 1;
				return 0;
			}
		} while (rp_ascii_is_horizontal_whitespace(byte));
	} else {
		index = saved;
	}

	size_t keyword_index = index;
	if (!rp_declaration_consume_word(line, length, &index, "class", case_insensitive, fallback_required)) {
		index = keyword_index;
		if (!rp_declaration_consume_word(line, length, &index, "struct", case_insensitive, fallback_required)) {
			index = keyword_index;
			if (!rp_declaration_consume_word(line, length, &index, "func", case_insensitive, fallback_required)) {
				return 0;
			}
		}
	}

	if (index >= length) return 0;
	uint8_t byte = line[index];
	if (byte >= 0x80) {
		*fallback_required = 1;
		return 0;
	}
	if (!rp_ascii_is_horizontal_whitespace(byte)) return 0;
	do {
		index++;
		if (index >= length) return 0;
		byte = line[index];
		if (byte >= 0x80) {
			*fallback_required = 1;
			return 0;
		}
	} while (rp_ascii_is_horizontal_whitespace(byte));

	return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || byte == '_';
}

int rp_pcre2_ascii_declaration_line_scan_8(const uint8_t *subject, size_t length, int case_insensitive, size_t *line_numbers_out, size_t line_numbers_capacity, size_t *collected_count_out, size_t *line_count_out, int *fallback_required_out) {
	if (collected_count_out != NULL) *collected_count_out = 0;
	if (line_count_out != NULL) *line_count_out = 0;
	if (fallback_required_out != NULL) *fallback_required_out = 0;
	if (subject == NULL) return -1;

	size_t line_count = 0;
	size_t collected_count = 0;
	size_t line_number = 0;
	size_t index = 0;

	while (index < length) {
		size_t line_start = index;
		size_t line_end = index;
		while (line_end < length && subject[line_end] != '\n' && subject[line_end] != '\r') {
			line_end++;
		}

		int fallback_required = 0;
		if (rp_declaration_line_matches(subject + line_start, line_end - line_start, case_insensitive, &fallback_required)) {
			if (line_numbers_out != NULL && collected_count < line_numbers_capacity) {
				line_numbers_out[collected_count] = line_number;
				collected_count++;
			}
			line_count++;
		}
		if (fallback_required) {
			if (fallback_required_out != NULL) *fallback_required_out = 1;
			return 0;
		}

		if (line_end >= length) break;
		uint8_t delimiter = subject[line_end];
		index = line_end + 1;
		if (delimiter == '\r' && index < length && subject[index] == '\n') index++;
		line_number++;
	}

	if (collected_count_out != NULL) *collected_count_out = collected_count;
	if (line_count_out != NULL) *line_count_out = line_count;
	return 0;
}

static int rp_ascii_is_digit(uint8_t byte) {
	return byte >= '0' && byte <= '9';
}

static int rp_ascii_is_regex_whitespace(uint8_t byte) {
	return byte == 0x09 || byte == 0x0A || byte == 0x0B || byte == 0x0C || byte == 0x0D || byte == 0x20;
}

static int rp_ascii_bytes_equal(const uint8_t *subject, size_t offset, const uint8_t *needle, size_t needle_length, int case_insensitive) {
	for (size_t index = 0; index < needle_length; index++) {
		uint8_t hay = subject[offset + index];
		uint8_t expected = needle[index];
		if ((case_insensitive ? rp_ascii_lower(hay) : hay) != expected) return 0;
	}
	return 1;
}

static int rp_ascii_marker_match_at(const uint8_t *subject, size_t length, size_t offset, const uint8_t *marker, size_t marker_length, uint32_t digit_count, const uint8_t *required_prefix, size_t required_prefix_length, int case_insensitive) {
	if (marker_length == 0 || required_prefix_length == 0) return 0;
	if (offset > 0 && rp_ascii_is_word(subject[offset - 1])) return 0;
	if (offset + marker_length + 1 + digit_count + 1 >= length) return 0;
	if (!rp_ascii_bytes_equal(subject, offset, marker, marker_length, case_insensitive)) return 0;
	
	size_t index = offset + marker_length;
	if (subject[index] != '-') return 0;
	index++;
	for (uint32_t digit = 0; digit < digit_count; digit++) {
		if (index >= length || !rp_ascii_is_digit(subject[index])) return 0;
		index++;
	}
	if (index >= length || subject[index] != ':') return 0;
	index++;
	if (index >= length || !rp_ascii_is_regex_whitespace(subject[index])) return 0;
	while (index < length && rp_ascii_is_regex_whitespace(subject[index])) index++;
	if (index + required_prefix_length > length) return 0;
	return rp_ascii_bytes_equal(subject, index, required_prefix, required_prefix_length, case_insensitive);
}

static int rp_ascii_count_line_breaks_before_marker(const uint8_t *bytes, size_t length, size_t *line_number, int *matched_current_line) {
	const uintptr_t low_mask = ~(uintptr_t)0 / (uintptr_t)0xFF;
	const uintptr_t high_mask = low_mask * (uintptr_t)0x80;
	const uintptr_t newline_mask = low_mask * (uintptr_t)'\n';
	const uintptr_t carriage_return_mask = low_mask * (uintptr_t)'\r';
	size_t index = 0;

	while (index + sizeof(uintptr_t) <= length) {
		uintptr_t chunk;
		memcpy(&chunk, bytes + index, sizeof(chunk));
		if ((chunk & high_mask) != 0) return 0;

		uintptr_t newline_probe = chunk ^ newline_mask;
		uintptr_t carriage_return_probe = chunk ^ carriage_return_mask;
		int has_newline = ((newline_probe - low_mask) & ~newline_probe & high_mask) != 0;
		int has_carriage_return = ((carriage_return_probe - low_mask) & ~carriage_return_probe & high_mask) != 0;
		if (!has_newline && !has_carriage_return) {
			index += sizeof(uintptr_t);
			continue;
		}

		int skip_lf_after_chunk = 0;
		for (size_t byte_index = 0; byte_index < sizeof(uintptr_t); byte_index++) {
			uint8_t byte = bytes[index + byte_index];
			if (byte == '\n') {
				(*line_number)++;
				*matched_current_line = 0;
			} else if (byte == '\r') {
				if (index + byte_index + 1 < length && bytes[index + byte_index + 1] == '\n') {
					if (byte_index + 1 < sizeof(uintptr_t)) {
						byte_index++;
					} else {
						skip_lf_after_chunk = 1;
					}
				}
				(*line_number)++;
				*matched_current_line = 0;
			}
		}
		index += sizeof(uintptr_t);
		if (skip_lf_after_chunk) index++;
	}

	while (index < length) {
		uint8_t byte = bytes[index];
		if (byte >= 0x80) return 0;
		if (byte == '\n') {
			(*line_number)++;
			*matched_current_line = 0;
		} else if (byte == '\r') {
			if (index + 1 < length && bytes[index + 1] == '\n') index++;
			(*line_number)++;
			*matched_current_line = 0;
		}
		index++;
	}

	return 1;
}

static int rp_ascii_count_line_breaks_and_starts_before_marker(const uint8_t *subject, size_t absolute_offset, size_t length, size_t *line_number, size_t *line_start, int *matched_current_line) {
	const uintptr_t low_mask = ~(uintptr_t)0 / (uintptr_t)0xFF;
	const uintptr_t high_mask = low_mask * (uintptr_t)0x80;
	const uintptr_t newline_mask = low_mask * (uintptr_t)'\n';
	const uintptr_t carriage_return_mask = low_mask * (uintptr_t)'\r';
	size_t index = 0;

	while (index + sizeof(uintptr_t) <= length) {
		uintptr_t chunk;
		memcpy(&chunk, subject + absolute_offset + index, sizeof(chunk));
		if ((chunk & high_mask) != 0) return 0;

		uintptr_t newline_probe = chunk ^ newline_mask;
		uintptr_t carriage_return_probe = chunk ^ carriage_return_mask;
		int has_newline = ((newline_probe - low_mask) & ~newline_probe & high_mask) != 0;
		int has_carriage_return = ((carriage_return_probe - low_mask) & ~carriage_return_probe & high_mask) != 0;
		if (!has_newline && !has_carriage_return) {
			index += sizeof(uintptr_t);
			continue;
		}

		int skip_lf_after_chunk = 0;
		for (size_t byte_index = 0; byte_index < sizeof(uintptr_t); byte_index++) {
			size_t absolute = absolute_offset + index + byte_index;
			uint8_t byte = subject[absolute];
			if (byte == '\n') {
				(*line_number)++;
				*line_start = absolute + 1;
				*matched_current_line = 0;
			} else if (byte == '\r') {
				size_t next_line_start = absolute + 1;
				if (index + byte_index + 1 < length && subject[absolute + 1] == '\n') {
					next_line_start = absolute + 2;
					if (byte_index + 1 < sizeof(uintptr_t)) {
						byte_index++;
					} else {
						skip_lf_after_chunk = 1;
					}
				}
				(*line_number)++;
				*line_start = next_line_start;
				*matched_current_line = 0;
			}
		}
		index += sizeof(uintptr_t);
		if (skip_lf_after_chunk) index++;
	}

	while (index < length) {
		size_t absolute = absolute_offset + index;
		uint8_t byte = subject[absolute];
		if (byte >= 0x80) return 0;
		if (byte == '\n') {
			(*line_number)++;
			*line_start = absolute + 1;
			*matched_current_line = 0;
		} else if (byte == '\r') {
			if (index + 1 < length && subject[absolute + 1] == '\n') {
				index++;
				absolute++;
			}
			(*line_number)++;
			*line_start = absolute + 1;
			*matched_current_line = 0;
		}
		index++;
	}

	return 1;
}

int rp_pcre2_ascii_marker_line_range_scan_8(const uint8_t *subject, size_t length, const uint8_t *marker, size_t marker_length, uint32_t digit_count, const uint8_t *required_prefix, size_t required_prefix_length, int case_insensitive, size_t *line_numbers_out, size_t *line_starts_out, size_t *line_ends_out, size_t line_capacity, size_t *collected_count_out, size_t *line_count_out, int *non_ascii_out) {
	if (collected_count_out != NULL) *collected_count_out = 0;
	if (line_count_out != NULL) *line_count_out = 0;
	if (non_ascii_out != NULL) *non_ascii_out = 0;
	if (subject == NULL || marker == NULL || required_prefix == NULL || marker_length == 0 || required_prefix_length == 0 || digit_count == 0) return -1;

	size_t line_count = 0;
	size_t collected_count = 0;
	size_t line_number = 0;
	size_t index = 0;

	if (!case_insensitive) {
		int matched_current_line = 0;
		size_t line_start = 0;
		while (index < length) {
			const uint8_t *hit_pointer = (const uint8_t *)memchr(subject + index, marker[0], length - index);
			size_t scan_end = hit_pointer == NULL ? length : (size_t)(hit_pointer - subject);

			if (!rp_ascii_count_line_breaks_and_starts_before_marker(subject, index, scan_end - index, &line_number, &line_start, &matched_current_line)) {
				if (non_ascii_out != NULL) *non_ascii_out = 1;
				return 0;
			}

			if (hit_pointer == NULL) break;
			if (!matched_current_line && rp_ascii_marker_match_at(subject, length, scan_end, marker, marker_length, digit_count, required_prefix, required_prefix_length, 0)) {
				size_t line_end = scan_end;
				while (line_end < length) {
					uint8_t byte = subject[line_end];
					if (byte >= 0x80) {
						if (non_ascii_out != NULL) *non_ascii_out = 1;
						return 0;
					}
					if (byte == '\n' || byte == '\r') break;
					line_end++;
				}
				if (line_numbers_out != NULL && line_starts_out != NULL && line_ends_out != NULL && collected_count < line_capacity) {
					line_numbers_out[collected_count] = line_number;
					line_starts_out[collected_count] = line_start;
					line_ends_out[collected_count] = line_end;
					collected_count++;
				}
				line_count++;
				matched_current_line = 1;
			}
			index = scan_end + 1;
		}

		if (collected_count_out != NULL) *collected_count_out = collected_count;
		if (line_count_out != NULL) *line_count_out = line_count;
		return 0;
	}

	while (index < length) {
		size_t line_start = index;
		size_t line_end = index;
		while (line_end < length) {
			uint8_t byte = subject[line_end];
			if (byte >= 0x80) {
				if (non_ascii_out != NULL) *non_ascii_out = 1;
				return 0;
			}
			if (byte == '\n' || byte == '\r') break;
			line_end++;
		}

		int matched_line = 0;
		if (!case_insensitive) {
			const uint8_t *cursor = subject + line_start;
			const uint8_t *end = subject + line_end;
			while (!matched_line && (size_t)(end - cursor) >= marker_length) {
				const uint8_t *hit = (const uint8_t *)memchr(cursor, marker[0], (size_t)(end - cursor));
				if (hit == NULL || (size_t)(end - hit) < marker_length) break;
				size_t candidate = (size_t)(hit - subject);
				if (rp_ascii_marker_match_at(subject, length, candidate, marker, marker_length, digit_count, required_prefix, required_prefix_length, 0)) {
					matched_line = 1;
				}
				cursor = hit + 1;
			}
		} else {
			uint8_t first = rp_ascii_lower(marker[0]);
			for (size_t candidate = line_start; candidate < line_end && !matched_line; candidate++) {
				if (rp_ascii_lower(subject[candidate]) == first && candidate + marker_length <= line_end && rp_ascii_marker_match_at(subject, length, candidate, marker, marker_length, digit_count, required_prefix, required_prefix_length, 1)) {
					matched_line = 1;
				}
			}
		}
		if (matched_line) {
			if (line_numbers_out != NULL && line_starts_out != NULL && line_ends_out != NULL && collected_count < line_capacity) {
				line_numbers_out[collected_count] = line_number;
				line_starts_out[collected_count] = line_start;
				line_ends_out[collected_count] = line_end;
				collected_count++;
			}
			line_count++;
		}

		if (line_end >= length) break;
		uint8_t delimiter = subject[line_end];
		index = line_end + 1;
		if (delimiter == '\r' && index < length && subject[index] == '\n') index++;
		line_number++;
	}

	if (collected_count_out != NULL) *collected_count_out = collected_count;
	if (line_count_out != NULL) *line_count_out = line_count;
	return 0;
}

int rp_pcre2_ascii_marker_line_scan_8(const uint8_t *subject, size_t length, const uint8_t *marker, size_t marker_length, uint32_t digit_count, const uint8_t *required_prefix, size_t required_prefix_length, int case_insensitive, size_t *line_numbers_out, size_t line_numbers_capacity, size_t *collected_count_out, size_t *line_count_out, int *non_ascii_out) {
	if (collected_count_out != NULL) *collected_count_out = 0;
	if (line_count_out != NULL) *line_count_out = 0;
	if (non_ascii_out != NULL) *non_ascii_out = 0;
	if (subject == NULL || marker == NULL || required_prefix == NULL || marker_length == 0 || required_prefix_length == 0 || digit_count == 0) return -1;

	size_t line_count = 0;
	size_t collected_count = 0;
	size_t line_number = 0;
	size_t index = 0;

	if (!case_insensitive) {
		int matched_current_line = 0;
		while (index < length) {
			const uint8_t *hit_pointer = (const uint8_t *)memchr(subject + index, marker[0], length - index);
			size_t scan_end = hit_pointer == NULL ? length : (size_t)(hit_pointer - subject);

			if (!rp_ascii_count_line_breaks_before_marker(subject + index, scan_end - index, &line_number, &matched_current_line)) {
				if (non_ascii_out != NULL) *non_ascii_out = 1;
				return 0;
			}

			if (hit_pointer == NULL) break;
			if (!matched_current_line && rp_ascii_marker_match_at(subject, length, scan_end, marker, marker_length, digit_count, required_prefix, required_prefix_length, 0)) {
				if (line_numbers_out != NULL && collected_count < line_numbers_capacity) {
					line_numbers_out[collected_count] = line_number;
					collected_count++;
				}
				line_count++;
				matched_current_line = 1;
			}
			index = scan_end + 1;
		}

		if (collected_count_out != NULL) *collected_count_out = collected_count;
		if (line_count_out != NULL) *line_count_out = line_count;
		return 0;
	}

	while (index < length) {
		size_t line_start = index;
		size_t line_end = index;
		while (line_end < length) {
			uint8_t byte = subject[line_end];
			if (byte >= 0x80) {
				if (non_ascii_out != NULL) *non_ascii_out = 1;
				return 0;
			}
			if (byte == '\n' || byte == '\r') break;
			line_end++;
		}

		int matched_line = 0;
		if (!case_insensitive) {
			const uint8_t *cursor = subject + line_start;
			const uint8_t *end = subject + line_end;
			while (!matched_line && (size_t)(end - cursor) >= marker_length) {
				const uint8_t *hit = (const uint8_t *)memchr(cursor, marker[0], (size_t)(end - cursor));
				if (hit == NULL || (size_t)(end - hit) < marker_length) break;
				size_t candidate = (size_t)(hit - subject);
				if (rp_ascii_marker_match_at(subject, length, candidate, marker, marker_length, digit_count, required_prefix, required_prefix_length, 0)) {
					matched_line = 1;
				}
				cursor = hit + 1;
			}
		} else {
			uint8_t first = rp_ascii_lower(marker[0]);
			for (size_t candidate = line_start; candidate < line_end && !matched_line; candidate++) {
				if (rp_ascii_lower(subject[candidate]) == first && candidate + marker_length <= line_end && rp_ascii_marker_match_at(subject, length, candidate, marker, marker_length, digit_count, required_prefix, required_prefix_length, 1)) {
					matched_line = 1;
				}
			}
		}
		if (matched_line) {
			if (line_numbers_out != NULL && collected_count < line_numbers_capacity) {
				line_numbers_out[collected_count] = line_number;
				collected_count++;
			}
			line_count++;
		}

		if (line_end >= length) break;
		uint8_t delimiter = subject[line_end];
		index = line_end + 1;
		if (delimiter == '\r' && index < length && subject[index] == '\n') index++;
		line_number++;
	}

	if (collected_count_out != NULL) *collected_count_out = collected_count;
	if (line_count_out != NULL) *line_count_out = line_count;
	return 0;
}

int rp_pcre2_config_jit_8(void) {
	uint32_t enabled = 0;
	int rc = pcre2_config(PCRE2_CONFIG_JIT, &enabled);
	if (rc < 0) return rc;
	return enabled ? 1 : 0;
}

int rp_pcre2_jit_compile_8(RPPCRE2Code *code, uint32_t options) {
	return pcre2_jit_compile((pcre2_code *)code, options);
}

int rp_pcre2_jit_size_8(const RPPCRE2Code *code, size_t *size_out) {
	PCRE2_SIZE jit_size = 0;
	int rc = pcre2_pattern_info((const pcre2_code *)code, PCRE2_INFO_JITSIZE, &jit_size);
	if (size_out != NULL) {
		*size_out = (size_t)jit_size;
	}
	return rc;
}

uint32_t rp_pcre2_option_utf_8(void) { return PCRE2_UTF; }
uint32_t rp_pcre2_option_ucp_8(void) { return PCRE2_UCP; }
uint32_t rp_pcre2_option_caseless_8(void) { return PCRE2_CASELESS; }
uint32_t rp_pcre2_option_multiline_8(void) { return PCRE2_MULTILINE; }
uint32_t rp_pcre2_option_dotall_8(void) { return PCRE2_DOTALL; }
uint32_t rp_pcre2_option_no_utf_check_8(void) { return PCRE2_NO_UTF_CHECK; }
uint32_t rp_pcre2_option_notbol_8(void) { return PCRE2_NOTBOL; }
uint32_t rp_pcre2_option_noteol_8(void) { return PCRE2_NOTEOL; }
uint32_t rp_pcre2_jit_complete_8(void) { return PCRE2_JIT_COMPLETE; }
int rp_pcre2_error_nomatch_8(void) { return PCRE2_ERROR_NOMATCH; }
int rp_pcre2_error_jit_unsupported_8(void) { return PCRE2_ERROR_JIT_UNSUPPORTED; }
int rp_pcre2_error_jit_badoption_8(void) { return PCRE2_ERROR_JIT_BADOPTION; }
int rp_pcre2_error_matchlimit_8(void) { return PCRE2_ERROR_MATCHLIMIT; }
int rp_pcre2_error_depthlimit_8(void) { return PCRE2_ERROR_DEPTHLIMIT; }
int rp_pcre2_error_heaplimit_8(void) { return PCRE2_ERROR_HEAPLIMIT; }
int rp_pcre2_error_jit_stacklimit_8(void) { return PCRE2_ERROR_JIT_STACKLIMIT; }
size_t rp_pcre2_unset_8(void) { return PCRE2_UNSET; }
