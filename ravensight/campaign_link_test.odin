// campaign_link_test.odin - set_campaign_link and the once rule on
// POST /session, through the fake transport. The same contract as
// ravensight-js: a link id goes once, lower cased, as campaignLink on the
// player's next session, and is forgotten only when that session is
// accepted with a token.

package ravensight

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
LINK :: "64b0000000000000000000a1"
@(private = "file")
OTHER :: "0123456789abcdef01234567"

@(private = "file")
Scripted :: struct {
	status: int,
	body:   string,
}

// Answers sessions 1, 2, ... with 201 and a token after `session_answers`
// runs out, and the first `batch_401s` batches with 401 (so the client
// opens a new session). `hold_sessions` leaves /session requests open.
@(private = "file")
Link_Server :: struct {
	sessions:        int,
	session_answers: []Scripted,
	batch_401s:      int,
	hold_sessions:   bool,
}

// Ticks the client and answers every open request until nothing is left.
@(private = "file")
serve_links :: proc(f: ^Fake, cl: ^Client, s: ^Link_Server) {
	for _ in 0 ..< 60 {
		tick(cl)
		idx := -1
		for r, i in f.requests {
			if !r.answered && !(s.hold_sessions && r.path == "/session") {
				idx = i
				break
			}
		}
		if idx < 0 {
			return
		}
		path := f.requests[idx].path
		switch {
		case path == "/settings":
			answer(f, idx, 200, `{"trackingEnabled":true}`)
		case path == "/session":
			n := s.sessions
			s.sessions += 1
			if n < len(s.session_answers) {
				answer(f, idx, s.session_answers[n].status, s.session_answers[n].body)
			} else {
				answer(f, idx, 201, fmt.tprintf(`{{"token":"tok_%d","expiresIn":86400}}`, n + 1))
			}
		case path == "/track/batch" && s.batch_401s > 0:
			s.batch_401s -= 1
			answer(f, idx, 401, `{"error":"invalid_session"}`)
		case path == "/track/batch":
			answer(f, idx, 202, `{}`)
		case:
			answer(f, idx, 0)
		}
	}
}

// The campaignLink of every POST /session so far, in order; "" where none
// was sent, "(empty)" where the key was sent with an empty value.
@(private = "file")
sent_links :: proc(f: ^Fake) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for r in f.requests {
		if r.path != "/session" {
			continue
		}
		parsed, err := json.parse_string(r.body, allocator = context.temp_allocator)
		obj, _ := parsed.(json.Object)
		link := ""
		if v, has := obj["campaignLink"]; has && err == nil {
			s, _ := v.(json.String)
			link = len(s) > 0 ? string(s) : "(empty)"
		}
		append(&out, link)
	}
	return out[:]
}

@(private = "file")
expect_links :: proc(t: ^testing.T, f: ^Fake, want: []string, loc := #caller_location) {
	got := sent_links(f)
	testing.expectf(t, len(got) == len(want), "sessions: got %v, want %v", got, want, loc = loc)
	for i in 0 ..< min(len(got), len(want)) {
		testing.expectf(t, got[i] == want[i], "session %d: got %q, want %q (all: %v)", i + 1, got[i], want[i], got, loc = loc)
	}
}

// Queues one event and serves until the client is quiet.
@(private = "file")
send_one :: proc(f: ^Fake, cl: ^Client, s: ^Link_Server) {
	track(cl, "tick")
	flush(cl, true)
	serve_links(f, cl, s)
}

@(private = "file")
nothing_saved :: proc(f: ^Fake) -> bool {
	data, err := os.read_entire_file(storage_in(f), context.temp_allocator)
	if err != nil {
		return true
	}
	text := string(data)
	return !strings.contains(text, LINK) && !strings.contains(text, strings.to_upper(LINK, context.temp_allocator))
}

// --- The id check -------------------------------------------------------------------

@(test)
test_campaign_link_id_accepts_24_hex_in_any_case_lower_cased :: proc(t: ^testing.T) {
	buf: [24]u8
	got, ok := campaign_link_id(LINK, &buf)
	testing.expect(t, ok)
	testing.expect_value(t, got, LINK)
	got, ok = campaign_link_id("64B0000000000000000000A1", &buf)
	testing.expect(t, ok)
	testing.expect_value(t, got, LINK)
	got, ok = campaign_link_id("ABCDEFabcdef0123456789Ab", &buf)
	testing.expect(t, ok)
	testing.expect_value(t, got, "abcdefabcdef0123456789ab")
}

@(test)
test_campaign_link_id_refuses_anything_else :: proc(t: ^testing.T) {
	refused := []string{
		"",
		LINK[:23],
		LINK + "0",
		"gggggggggggggggggggggggg",
		" " + LINK[1:],
		LINK[1:] + " ",
		" " + LINK,
		LINK + " ",
		"0x" + LINK[2:],
		"64b000000000-000000000a1",
		"64b000000000000000000\x00a1",
		"64b00000000000000000000é",
	}
	buf: [24]u8
	for text in refused {
		_, ok := campaign_link_id(text, &buf)
		testing.expectf(t, !ok, "accepted %q", text)
	}
}

// --- set_campaign_link and the once rule -----------------------------------------

@(test)
test_campaign_link_goes_lower_cased_on_the_first_session_and_never_again :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := Link_Server{batch_401s = 1} // the first batch's session is refused: a second opens
	cl := fake_client(t, &f, Config{})
	testing.expect(t, set_campaign_link(cl, "64B0000000000000000000A1"))
	send_one(&f, cl, &s)
	expect_links(t, &f, {LINK, ""})
	// A new device id opens a third session, which carries none either.
	reset_device_id(cl)
	send_one(&f, cl, &s)
	expect_links(t, &f, {LINK, "", ""})
	testing.expect(t, nothing_saved(&f))
	close_client(cl)
}

@(test)
test_campaign_link_set_returns_false_for_anything_but_a_link_id_and_keeps_the_waiting_one :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s: Link_Server
	cl := fake_client(t, &f, Config{})
	testing.expect(t, set_campaign_link(cl, LINK))
	for text in ([]string{"", LINK[:23], LINK + "0", "gggggggggggggggggggggggg", " " + LINK, LINK + " ", " " + LINK[1:]}) {
		testing.expectf(t, !set_campaign_link(cl, text), "accepted %q", text)
	}
	send_one(&f, cl, &s)
	expect_links(t, &f, {LINK})
	close_client(cl)
}

@(test)
test_campaign_link_nothing_is_sent_when_every_set_was_refused :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s: Link_Server
	cl := fake_client(t, &f, Config{})
	testing.expect(t, !set_campaign_link(cl, "abc"))
	testing.expect(t, !set_campaign_link(cl, "gggggggggggggggggggggggg"))
	send_one(&f, cl, &s)
	expect_links(t, &f, {""})
	testing.expect(t, !set_campaign_link(nil, LINK))
	close_client(cl)
}

@(test)
test_campaign_link_a_later_valid_set_replaces_the_waiting_one :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s: Link_Server
	cl := fake_client(t, &f, Config{})
	testing.expect(t, set_campaign_link(cl, LINK))
	testing.expect(t, set_campaign_link(cl, "0123456789ABCDEF01234567"))
	send_one(&f, cl, &s)
	expect_links(t, &f, {OTHER})
	close_client(cl)
}

@(test)
test_campaign_link_set_after_the_first_session_goes_with_the_next_session :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s: Link_Server
	cl := fake_client(t, &f, Config{})
	send_one(&f, cl, &s)
	testing.expect(t, set_campaign_link(cl, LINK))
	s.batch_401s = 1
	send_one(&f, cl, &s)
	expect_links(t, &f, {"", LINK})
	close_client(cl)
}

@(test)
test_campaign_link_a_failed_or_refused_session_keeps_it_for_the_next_attempt :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	answers := []Scripted{
		{500, `{"error":"internal_error"}`},
		{0, ""}, // no answer (timed out)
		{429, `{"error":"rate_limited"}`},
		{201, `{"expiresIn":86400}`}, // 201 with no token
	}
	s := Link_Server{session_answers = answers, batch_401s = 1}
	cl := fake_client(t, &f, Config{})
	testing.expect(t, set_campaign_link(cl, LINK))
	for _ in 0 ..< 8 {
		if len(sent_links(&f)) >= 6 {
			break
		}
		f.now += 300_000 // past any backoff or Retry-After
		send_one(&f, cl, &s)
	}
	// Four failures carry it, the accepted fifth carries it and clears it, the sixth has none.
	expect_links(t, &f, {LINK, LINK, LINK, LINK, LINK, ""})
	close_client(cl)
}

@(test)
test_campaign_link_set_while_a_session_is_in_flight_waits_for_the_next_session :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := Link_Server{hold_sessions = true, batch_401s = 1}
	cl := fake_client(t, &f, Config{})
	testing.expect(t, set_campaign_link(cl, LINK))
	send_one(&f, cl, &s)
	testing.expect_value(t, count_requests(&f, "/session"), 1)
	// The open session already carries LINK; OTHER is for the next one.
	testing.expect(t, set_campaign_link(cl, OTHER))
	s.hold_sessions = false
	serve_links(&f, cl, &s)
	expect_links(t, &f, {LINK, OTHER})
	close_client(cl)
}

// --- Gates ------------------------------------------------------------------------------

@(test)
test_campaign_link_waits_for_consent_and_goes_with_the_first_session_after_the_yes :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s: Link_Server
	cl := fake_client(t, &f, Config{consent = .Opt_In})
	testing.expect(t, set_campaign_link(cl, LINK))
	send_one(&f, cl, &s)
	testing.expect_value(t, len(f.requests), 0)
	set_tracking_enabled(cl, true)
	send_one(&f, cl, &s)
	expect_links(t, &f, {LINK})
	testing.expect(t, nothing_saved(&f))
	close_client(cl)
}

@(test)
test_campaign_link_an_opted_out_player_sends_nothing :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s: Link_Server
	testing.expect(t, write_tracking_enabled(false, storage_in(&f)))
	cl := fake_client(t, &f, Config{})
	testing.expect(t, set_campaign_link(cl, LINK))
	send_one(&f, cl, &s)
	testing.expect_value(t, count_requests(&f, "/session"), 0)
	testing.expect(t, nothing_saved(&f))
	close_client(cl)
}

@(test)
test_campaign_link_waits_while_the_game_switched_sending_off :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s: Link_Server
	cl := fake_client(t, &f, Config{start_disabled = true})
	testing.expect(t, set_campaign_link(cl, LINK))
	send_one(&f, cl, &s)
	testing.expect_value(t, count_requests(&f, "/session"), 0)
	set_enabled(cl, true)
	send_one(&f, cl, &s)
	expect_links(t, &f, {LINK})
	close_client(cl)
}

@(test)
test_campaign_link_without_a_key_nothing_is_sent :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	transport := Transport{user = &f, send = fake_send, now = fake_now, idle = fake_idle}
	cl, err := create_with_transport(Config{optional = true, storage_path = storage_in(&f)}, transport, false)
	testing.expect_value(t, err, Error.None)
	f.client = cl
	testing.expect(t, set_campaign_link(cl, LINK))
	track(cl, "tick")
	flush(cl, true)
	for _ in 0 ..< 10 {
		tick(cl)
	}
	testing.expect_value(t, len(f.requests), 0)
	testing.expect(t, nothing_saved(&f))
	close_client(cl)
}

@(test)
test_campaign_link_a_playtest_run_never_sends_it :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := Link_Server{batch_401s = 1}
	cl := fake_client(t, &f, Config{playtest_token = "pt_token", playtest_run_id = "run_7"})
	testing.expect(t, set_campaign_link(cl, LINK))
	send_one(&f, cl, &s)
	expect_links(t, &f, {"", ""})
	close_client(cl)
}
