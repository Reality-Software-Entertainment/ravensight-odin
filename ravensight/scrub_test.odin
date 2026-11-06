// scrub_test.odin - the device scrub, rule by rule, against the contract.

package ravensight

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:time"

expect_scrub :: proc(t: ^testing.T, input, want: string, loc := #caller_location) {
	got := scrub_error_text(input)
	testing.expect_value(t, got, want, loc = loc)
	// Idempotent: scrubbing scrubbed text changes nothing.
	testing.expect_value(t, scrub_error_text(got), got, loc = loc)
}

@(test)
test_scrub_urls_lose_query_fragment_and_userinfo :: proc(t: ^testing.T) {
	expect_scrub(t, "GET https://api.example.com/v1/x?token=abc#frag failed", "GET https://api.example.com/v1/x failed")
	expect_scrub(t, "see http://user:pw@host.test/a/b ok", "see http://host.test/a/b ok")
	expect_scrub(t, "res://scenes/level.tscn", "res://scenes/level.tscn")
}

@(test)
test_scrub_tokens_and_keys :: proc(t: ^testing.T) {
	expect_scrub(t, "auth Bearer abc.DEF-123/x== denied", "auth [token] denied")
	expect_scrub(t, "jwt eyJhbGciOi.eyJzdWIi.c2lnbmF0dXJl end", "jwt [token] end")
	expect_scrub(t, "key gt_live_abc123 refused", "key [token] refused")
	expect_scrub(t, "key gt_pub_XYZ", "key [token]")
}

@(test)
test_scrub_emails :: proc(t: ^testing.T) {
	expect_scrub(t, "mail player.one+x@mail.example.org bounced", "mail [email] bounced")
	expect_scrub(t, "a@b@c.com", "a@[email]")
	expect_scrub(t, "not an email: name@host", "not an email: name@host")
}

@(test)
test_scrub_home_paths_become_tilde :: proc(t: ^testing.T) {
	expect_scrub(t, "open /Users/jacob/game/save.dat", "open ~/game/save.dat")
	expect_scrub(t, "open /home/sam/.local/share/x", "open ~/.local/share/x")
	expect_scrub(t, `open C:\Users\Sam\AppData\x`, `open ~\AppData\x`)
	expect_scrub(t, "open d:/users/Sam/x", "open ~/x")
	expect_scrub(t, "/usr/local/lib", "/usr/local/lib")
}

@(test)
test_scrub_ip_addresses :: proc(t: ^testing.T) {
	expect_scrub(t, "connect 192.168.1.20:7777 refused", "connect [ip]:7777 refused")
	expect_scrub(t, "v 1.2.3.4.5", "v [ip].5")
	expect_scrub(t, "host 2001:0db8:85a3:0000:0000:8a2e:0370:7334 down", "host [ip] down")
	expect_scrub(t, "host fe80::1 down", "host [ip] down")
	expect_scrub(t, "loopback ::1", "loopback [ip]")
	// An Odin scope operator with no digit is not an address.
	expect_scrub(t, "in pkg::update_player", "in pkg::update_player")
	expect_scrub(t, "version 1234.1.1.1", "version 1234.1.1.1")
}

@(test)
test_scrub_long_runs_need_a_digit :: proc(t: ^testing.T) {
	expect_scrub(t, "id 0123456789abcdef0123456789abcdef!", "id [token]!")
	expect_scrub(t, "b64 QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo1234+== end", "b64 [token] end")
	// No digit: a long snake_case procedure name survives.
	expect_scrub(t, "at on_pointer_click_handler_for_the_main_menu_screen", "at on_pointer_click_handler_for_the_main_menu_screen")
	// 31 characters with digits is under the length.
	expect_scrub(t, "abcdefghijklmnopqrstuvwxyz12345", "abcdefghijklmnopqrstuvwxyz12345")
}

// The shared cases every SDK and the server must produce exactly.
SCRUB_VECTORS :: #load("testdata/scrub-vectors.json", string)

@(test)
test_scrub_shared_vectors :: proc(t: ^testing.T) {
	parsed, err := json.parse_string(SCRUB_VECTORS, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root, _ := parsed.(json.Object)
	cases, _ := root["cases"].(json.Array)
	testing.expect(t, len(cases) >= 18)
	for c in cases {
		obj, _ := c.(json.Object)
		name, _ := obj["name"].(json.String)
		input, _ := obj["in"].(json.String)
		want, _ := obj["out"].(json.String)
		got := scrub_error_text(string(input))
		testing.expectf(t, got == string(want), "%s: got %q want %q", name, got, want)
	}
}

@(test)
test_scrub_secret_with_slashes_but_paths_survive :: proc(t: ^testing.T) {
	expect_scrub(t, "aws wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY1 leaked", "aws [token] leaked")
	expect_scrub(t, "Assets/Scripts/Inventory2/Slots/InventorySlotController.cs", "Assets/Scripts/Inventory2/Slots/InventorySlotController.cs")
	// A piece of 32 or more is never a path word.
	expect_scrub(t, "x/abcdefghijklmnopqrstuvwxyz0123456789", "[token]")
}

@(test)
test_scrub_long_path_with_digits_survives :: proc(t: ^testing.T) {
	// Every piece between slashes is a path word, and '.' ends the run.
	path := "src/levels/world2/chapter3_boss_fight_v2/arena_spawner_wave7.odin(142:9)"
	expect_scrub(t, path, path)
	expect_scrub(
		t,
		"at spawn (/home/dev/projects/game2026/src/levels/world2/boss3.odin:42:7)",
		"at spawn (~/projects/game2026/src/levels/world2/boss3.odin:42:7)",
	)
}

@(test)
test_scrub_empty_and_plain_text :: proc(t: ^testing.T) {
	expect_scrub(t, "", "")
	expect_scrub(t, "Player 42 not found", "Player 42 not found")
	expect_scrub(t, "héllo wörld ✓", "héllo wörld ✓")
}

@(test)
test_scrub_ipv6_needs_a_digit_and_urls_lose_userinfo :: proc(t: ^testing.T) {
	expect_scrub(t, "call Face::Add failed", "call Face::Add failed")
	expect_scrub(t, "aaaa:bbbb:cccc:dddd:eeee:ffff:abcd:dcba", "aaaa:bbbb:cccc:dddd:eeee:ffff:abcd:dcba")
	expect_scrub(t, "fetch https://admin:hunter2@cdn.example.com/a.png", "fetch https://cdn.example.com/a.png")
}

@(test)
test_scrub_is_fast_on_a_huge_line :: proc(t: ^testing.T) {
	patterns := [?]string{"a", "a.", "1", "1.", "a@", "a:", "/a", "x1y2", "eyJa."}
	for p in patterns {
		huge := strings.repeat(p, 200_000 / len(p), context.temp_allocator)
		start := time.tick_now()
		// The field path: cut to 4 times the limit, scrub, cut to the limit.
		field := scrub_field(huge, MAX_ERROR_STACK_CHARS)
		testing.expect(t, strings.rune_count(field) <= MAX_ERROR_STACK_CHARS)
		// The whole 200,000 characters, scrubbed directly, is linear too.
		_ = scrub_error_text(huge)
		elapsed := time.tick_since(start)
		testing.expectf(t, elapsed < 2 * time.Second, "%q took %v", p, elapsed)
	}
}
