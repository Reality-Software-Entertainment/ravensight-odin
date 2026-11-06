// scrub.odin - the device side of the error text scrub.
//
// Automatic captures are scrubbed here, before they are queued, with the
// rules the server applies again on ingest (the error capture contract,
// "Scrub"). In order:
//
//   1. A URL (scheme://...) loses its query, its fragment and any
//      user:password@ before the host.
//   2. "Bearer <token>", a JWT-shaped string (eyJ... dot ... dot ...) and a
//      gt_ key become [token].
//   3. An email address becomes [email].
//   4. C:\Users\<name> (either slash, any drive letter), /Users/<name> and
//      /home/<name> become ~.
//   5. An IPv4 address becomes [ip]; so does an IPv6 address written in
//      full (eight groups) or compressed with ::, when it has a digit.
//   6. A run of 32 or more characters from [A-Za-z0-9+/=_-] with at least
//      one digit in it becomes [token], unless it has a '/' and every piece
//      between slashes is empty or a path word (snake or kebab case, Pascal
//      case, or 1 to 6 upper-case letters and digits) under 32 characters.
//      The digit rule keeps long snake_case procedure names; the path rule
//      keeps file paths while a secret with slashes in it is still caught.
//
// Pure: no I/O, no clock, no state. scrub(scrub(x)) == scrub(x). Every
// matcher is a hand-written scan that keeps the leftmost-first meaning of
// the server's patterns; byte-wise, so multi-byte UTF-8 passes untouched.

package ravensight

import "core:strings"

// Scrubs `text` with the contract's rules. The result is allocated with
// `allocator` (the temp allocator by default).
scrub_error_text :: proc(text: string, allocator := context.temp_allocator) -> string {
	if len(text) == 0 {
		return strings.clone(text, allocator)
	}
	s := text
	s = scrub_pass(s, match_url)
	s = scrub_pass(s, match_bearer)
	s = scrub_pass(s, match_jwt)
	s = scrub_pass(s, match_gt_key)
	s = scrub_pass(s, match_email)
	s = scrub_pass(s, match_home_windows)
	s = scrub_pass(s, match_home_unix)
	s = scrub_pass(s, match_ipv4)
	s = scrub_pass(s, match_ipv6_full)
	s = scrub_pass(s, match_ipv6_short)
	s = scrub_pass(s, match_long_run)
	return strings.clone(s, allocator)
}

// A matcher looks for one match starting exactly at `i`. On a match it
// returns where the match ends and what replaces it (possibly the matched
// text itself, when a candidate is kept).
@(private)
Scrub_Matcher :: #type proc(s: string, i: int) -> (end: int, replacement: string, ok: bool)

// Replaces every leftmost, non-overlapping match, like a global regex
// replace. Allocates in the temp allocator.
@(private)
scrub_pass :: proc(s: string, match: Scrub_Matcher) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if end, rep, ok := match(s, i); ok && end > i {
			strings.write_string(&b, rep)
			i = end
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

@(private)
is_alpha_byte :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

@(private)
is_digit_byte :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
is_alnum_byte :: proc(c: u8) -> bool {
	return is_alpha_byte(c) || is_digit_byte(c)
}

@(private)
is_word_byte :: proc(c: u8) -> bool {
	return is_alnum_byte(c) || c == '_'
}

@(private)
is_hex_byte :: proc(c: u8) -> bool {
	return is_digit_byte(c) || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

@(private)
is_space_byte :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'
}

// A word boundary before s[i], given that s[i] is a word character.
@(private)
boundary_before :: proc(s: string, i: int) -> bool {
	return i == 0 || !is_word_byte(s[i - 1])
}

// A word boundary at `i`, given that s[i-1] is a word character.
@(private)
boundary_at :: proc(s: string, i: int) -> bool {
	return i >= len(s) || !is_word_byte(s[i])
}

@(private)
lower_byte :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

// Case-insensitive literal match at `i`.
@(private)
match_fold :: proc(s: string, i: int, lit: string) -> bool {
	if i + len(lit) > len(s) {
		return false
	}
	for k in 0 ..< len(lit) {
		if lower_byte(s[i + k]) != lower_byte(lit[k]) {
			return false
		}
	}
	return true
}

@(private)
has_digit :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if is_digit_byte(s[i]) {
			return true
		}
	}
	return false
}

// 1. scheme://[userinfo@]host/path[?query][#fragment] keeps scheme, host and path.
@(private)
match_url :: proc(s: string, i: int) -> (int, string, bool) {
	if !is_alpha_byte(s[i]) || !boundary_before(s, i) {
		return 0, "", false
	}
	j := i + 1
	for j < len(s) && (is_alnum_byte(s[j]) || s[j] == '+' || s[j] == '.' || s[j] == '-') {
		j += 1
	}
	if !strings.has_prefix(s[j:], "://") {
		return 0, "", false
	}
	j += 3
	head := s[i:j]
	k := j
	for k < len(s) {
		c := s[k]
		if is_space_byte(c) || c == '/' || c == '?' || c == '#' || c == '@' || c == '\'' || c == '"' || c == '<' || c == '>' {
			break
		}
		k += 1
	}
	if k < len(s) && s[k] == '@' {
		j = k + 1 // drop user:password@
	}
	p := j
	for p < len(s) {
		c := s[p]
		if is_space_byte(c) || c == '?' || c == '#' || c == '\'' || c == '"' || c == '<' || c == '>' {
			break
		}
		p += 1
	}
	path := s[j:p]
	q := p
	if q < len(s) && (s[q] == '?' || s[q] == '#') {
		for q < len(s) {
			c := s[q]
			if is_space_byte(c) || c == '\'' || c == '"' || c == '<' || c == '>' {
				break
			}
			q += 1
		}
	}
	return q, strings.concatenate({head, path}, context.temp_allocator), true
}

// 2a. Bearer <token>
@(private)
match_bearer :: proc(s: string, i: int) -> (int, string, bool) {
	if !boundary_before(s, i) || !match_fold(s, i, "bearer") {
		return 0, "", false
	}
	j := i + 6
	if j >= len(s) || !is_space_byte(s[j]) {
		return 0, "", false
	}
	for j < len(s) && is_space_byte(s[j]) {
		j += 1
	}
	start := j
	for j < len(s) {
		c := s[j]
		if !(is_alnum_byte(c) || c == '-' || c == '.' || c == '_' || c == '~' || c == '+' || c == '/') {
			break
		}
		j += 1
	}
	if j == start {
		return 0, "", false
	}
	for j < len(s) && s[j] == '=' {
		j += 1
	}
	return j, "[token]", true
}

@(private)
is_jwt_byte :: proc(c: u8) -> bool {
	return is_alnum_byte(c) || c == '_' || c == '-'
}

// 2b. eyJ<segment>.<segment>.<segment?>
@(private)
match_jwt :: proc(s: string, i: int) -> (int, string, bool) {
	if !boundary_before(s, i) || !strings.has_prefix(s[i:], "eyJ") {
		return 0, "", false
	}
	j := i + 3
	start := j
	for j < len(s) && is_jwt_byte(s[j]) {j += 1}
	if j == start || j >= len(s) || s[j] != '.' {
		return 0, "", false
	}
	j += 1
	start = j
	for j < len(s) && is_jwt_byte(s[j]) {j += 1}
	if j == start || j >= len(s) || s[j] != '.' {
		return 0, "", false
	}
	j += 1
	for j < len(s) && is_jwt_byte(s[j]) {j += 1}
	return j, "[token]", true
}

// 2c. gt_<key>
@(private)
match_gt_key :: proc(s: string, i: int) -> (int, string, bool) {
	if !boundary_before(s, i) || !strings.has_prefix(s[i:], "gt_") {
		return 0, "", false
	}
	j := i + 3
	start := j
	for j < len(s) && is_word_byte(s[j]) {j += 1}
	if j == start {
		return 0, "", false
	}
	return j, "[token]", true
}

@(private)
is_email_local_byte :: proc(c: u8) -> bool {
	return is_alnum_byte(c) || c == '.' || c == '_' || c == '%' || c == '+' || c == '-'
}

// 3. local@domain.tld, with the longest domain whose last label is 2+ letters.
@(private)
match_email :: proc(s: string, i: int) -> (int, string, bool) {
	if !is_email_local_byte(s[i]) {
		return 0, "", false
	}
	j := i
	for j < len(s) && is_email_local_byte(s[j]) {j += 1}
	if j >= len(s) || s[j] != '@' {
		return 0, "", false
	}
	d := j + 1
	e := d
	for e < len(s) && (is_alnum_byte(s[e]) || s[e] == '.' || s[e] == '-') {e += 1}
	for k := e - 1; k > d; k -= 1 {
		if s[k] != '.' {
			continue
		}
		n := k + 1
		for n < e && is_alpha_byte(s[n]) {n += 1}
		if n - (k + 1) >= 2 {
			return n, "[email]", true
		}
	}
	return 0, "", false
}

@(private)
is_path_name_byte :: proc(c: u8, backslash_too: bool) -> bool {
	if c == '/' || is_space_byte(c) || c == '\'' || c == '"' {
		return false
	}
	return !(backslash_too && c == '\\')
}

// 4a. C:\Users\<name> or C:/Users/<name>
@(private)
match_home_windows :: proc(s: string, i: int) -> (int, string, bool) {
	if !is_alpha_byte(s[i]) || !boundary_before(s, i) || i + 9 >= len(s) {
		return 0, "", false
	}
	if s[i + 1] != ':' || (s[i + 2] != '\\' && s[i + 2] != '/') || !match_fold(s, i + 3, "users") {
		return 0, "", false
	}
	if s[i + 8] != '\\' && s[i + 8] != '/' {
		return 0, "", false
	}
	j := i + 9
	start := j
	for j < len(s) && is_path_name_byte(s[j], true) {j += 1}
	if j == start {
		return 0, "", false
	}
	return j, "~", true
}

// 4b. /Users/<name> or /home/<name>
@(private)
match_home_unix :: proc(s: string, i: int) -> (int, string, bool) {
	if s[i] != '/' {
		return 0, "", false
	}
	rest := s[i + 1:]
	j: int
	if strings.has_prefix(rest, "Users/") {
		j = i + 7
	} else if strings.has_prefix(rest, "home/") {
		j = i + 6
	} else {
		return 0, "", false
	}
	start := j
	for j < len(s) && is_path_name_byte(s[j], false) {j += 1}
	if j == start {
		return 0, "", false
	}
	return j, "~", true
}

// The length of the run of `pred` bytes starting at `i`.
@(private)
run_of :: proc(s: string, i: int, pred: proc(c: u8) -> bool) -> int {
	j := i
	for j < len(s) && pred(s[j]) {j += 1}
	return j - i
}

// 5a. \b(\d{1,3}\.){3}\d{1,3}\b
@(private)
match_ipv4 :: proc(s: string, i: int) -> (int, string, bool) {
	if !is_digit_byte(s[i]) || !boundary_before(s, i) {
		return 0, "", false
	}
	j := i
	for g in 0 ..< 4 {
		n := run_of(s, j, is_digit_byte)
		if n < 1 || n > 3 {
			return 0, "", false
		}
		j += n
		if g < 3 {
			if j >= len(s) || s[j] != '.' {
				return 0, "", false
			}
			j += 1
		}
	}
	if !boundary_at(s, j) {
		return 0, "", false
	}
	return j, "[ip]", true
}

// 5b. \b([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b
@(private)
match_ipv6_full :: proc(s: string, i: int) -> (int, string, bool) {
	if !is_hex_byte(s[i]) || !boundary_before(s, i) {
		return 0, "", false
	}
	j := i
	for g in 0 ..< 8 {
		n := run_of(s, j, is_hex_byte)
		if n < 1 || n > 4 {
			return 0, "", false
		}
		j += n
		if g < 7 {
			if j >= len(s) || s[j] != ':' {
				return 0, "", false
			}
			j += 1
		}
	}
	if !boundary_at(s, j) {
		return 0, "", false
	}
	return j, "[ip]", true
}

// 5c. (\b h(:h){0,6})? :: (h(:h){0,6}\b)?  replaced by [ip] only when the
// match has a digit; a match without one is kept as it is.
@(private)
match_ipv6_short :: proc(s: string, i: int) -> (int, string, bool) {
	j := i
	if is_hex_byte(s[i]) && boundary_before(s, i) {
		k := i
		groups := 0
		for groups < 7 {
			n := run_of(s, k, is_hex_byte)
			if n < 1 || n > 4 {
				break
			}
			k += n
			groups += 1
			if strings.has_prefix(s[k:], "::") {
				j = k
				break
			}
			if k < len(s) && s[k] == ':' && groups < 7 {
				k += 1
				continue
			}
			break
		}
	}
	if !strings.has_prefix(s[j:], "::") {
		return 0, "", false
	}
	j += 2
	// The right part: groups separated by single ':', the longest prefix of
	// whole groups that ends on a word boundary.
	end := j
	k := j
	for g in 0 ..< 7 {
		n := run_of(s, k, is_hex_byte)
		if n < 1 || n > 4 {
			break
		}
		k += n
		if boundary_at(s, k) {
			end = k
		}
		if g < 6 && k + 1 < len(s) && s[k] == ':' && is_hex_byte(s[k + 1]) {
			k += 1
			continue
		}
		break
	}
	match := s[i:end]
	if has_digit(match) {
		return end, "[ip]", true
	}
	return end, match, true
}

@(private)
is_token_byte :: proc(c: u8) -> bool {
	return is_alnum_byte(c) || c == '+' || c == '/' || c == '=' || c == '_' || c == '-'
}

@(private)
is_lower_digit_byte :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || is_digit_byte(c)
}

@(private)
is_upper_byte :: proc(c: u8) -> bool {
	return c >= 'A' && c <= 'Z'
}

// A piece of a path between slashes that reads as a word: empty, snake or
// kebab case (`inventory_system2`), Pascal case (`InventorySlot2`), or a
// short upper-case tag (`UI`, `V2`).
@(private)
is_path_word :: proc(p: string) -> bool {
	if len(p) == 0 {
		return true
	}
	// ^[a-z0-9]+([_-][a-z0-9]+)*$
	snake := true
	prev_sep := true
	for i in 0 ..< len(p) {
		c := p[i]
		if is_lower_digit_byte(c) {
			prev_sep = false
		} else if (c == '_' || c == '-') && !prev_sep {
			prev_sep = true
		} else {
			snake = false
			break
		}
	}
	if snake && !prev_sep {
		return true
	}
	// ^[A-Z][a-z0-9]*(?:[A-Z][a-z0-9]+)*$
	if is_upper_byte(p[0]) {
		pascal := true
		i := 1
		for i < len(p) && is_lower_digit_byte(p[i]) {i += 1}
		for pascal && i < len(p) {
			if !is_upper_byte(p[i]) {
				pascal = false
				break
			}
			i += 1
			start := i
			for i < len(p) && is_lower_digit_byte(p[i]) {i += 1}
			if i == start {
				pascal = false
			}
		}
		if pascal {
			return true
		}
	}
	// ^[A-Z0-9]{1,6}$
	if len(p) <= 6 {
		for i in 0 ..< len(p) {
			if !(is_upper_byte(p[i]) || is_digit_byte(p[i])) {
				return false
			}
		}
		return true
	}
	return false
}

// A run with a slash whose every piece is a path word under 32 characters.
@(private)
is_path_run :: proc(run: string) -> bool {
	if strings.index_byte(run, '/') < 0 {
		return false
	}
	rest := run
	for piece in strings.split_iterator(&rest, "/") {
		if len(piece) >= 32 || !is_path_word(piece) {
			return false
		}
	}
	return true
}

// 6. [A-Za-z0-9+/=_-]{32,} with a digit in it, unless it reads as a path.
@(private)
match_long_run :: proc(s: string, i: int) -> (int, string, bool) {
	n := run_of(s, i, is_token_byte)
	if n < 32 {
		return 0, "", false
	}
	run := s[i:i + n]
	if has_digit(run) && !is_path_run(run) {
		return i + n, "[token]", true
	}
	return i + n, run, true
}
