// identify_test.odin - identify and reset_identity against the binding
// vectors (testdata/identify-vectors.json, version 2), read from the
// fixture, never hand typed, through the fake transport.

package ravensight

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

IDENTIFY_VECTORS :: #load("testdata/identify-vectors.json", string)

@(private = "file")
Vectors :: struct {
	root:     json.Object,
	salt:     string,
	accept:   json.Array,
	refuse:   json.Array,
	sequence: json.Array,
}

@(private = "file")
load_vectors :: proc(t: ^testing.T) -> (v: Vectors) {
	parsed, err := json.parse_string(IDENTIFY_VECTORS, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	v.root, _ = parsed.(json.Object)
	testing.expect_value(t, json_number_i64(v.root["version"]), 2)
	salt, _ := v.root["salt"].(json.String)
	v.salt = string(salt)
	v.accept, _ = v.root["accept"].(json.Array)
	v.refuse, _ = v.root["refuse"].(json.Array)
	v.sequence, _ = v.root["sequence"].(json.Array)
	return
}

// The accountHash a sequence step expects to see sent.
@(private = "file")
sent_hash :: proc(v: Vectors, step: int) -> string {
	expect, _ := v.sequence[step].(json.Object)["expect"].(json.Object)
	sends, _ := expect["sends"].(json.Array)
	if len(sends) == 0 {
		return "missing"
	}
	first, _ := sends[0].(json.Object)
	hash, _ := first["accountHash"].(json.String)
	return string(hash)
}

// --- A small server for the fake transport -------------------------------------

@(private = "file")
Server :: struct {
	token_prefix:   string, // session tokens are <prefix>_<n>
	sessions:       int,
	salt:           string, // "" sends no identify.salt
	identify_status: int,
	identify_body:  string,
	hold_identify:  bool, // leave /identify requests open
	batch_status:   int,  // 0 means 202
	batch_retry_ms: i64,
	next_session_body: string, // answers the next /session as is, once
}

@(private = "file")
server_make :: proc(v: Vectors, prefix: string) -> Server {
	return Server{token_prefix = prefix, salt = v.salt, identify_status = 200, identify_body = `{"playerId":"px_test","linked":true,"verified":false,"repeat":false}`}
}

@(private = "file")
is_identify :: proc(r: Fake_Request) -> bool {
	return r.path == "/identify"
}

// Ticks the client and answers every open request until nothing is left,
// /identify included unless held.
@(private = "file")
serve :: proc(f: ^Fake, cl: ^Client, s: ^Server) {
	for _ in 0 ..< 40 {
		tick(cl)
		idx := -1
		for r, i in f.requests {
			if !r.answered && !(s.hold_identify && is_identify(r)) {
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
		case path == "/session" && len(s.next_session_body) > 0:
			body := s.next_session_body
			s.next_session_body = ""
			answer(f, idx, 201, body)
		case path == "/session":
			s.sessions += 1
			extra := len(s.salt) > 0 ? fmt.tprintf(`,"identify":{{"salt":"%s"}}`, s.salt) : ""
			answer(f, idx, 201, fmt.tprintf(`{{"token":"%s_%d","expiresIn":86400%s}}`, s.token_prefix, s.sessions, extra))
		case path == "/identify":
			answer(f, idx, s.identify_status, s.identify_body)
		case path == "/track/batch" && s.batch_status != 0:
			answer(f, idx, s.batch_status, `{"error":"rate_limited"}`, s.batch_retry_ms)
		case path == "/track/batch":
			answer(f, idx, 202, `{}`)
		case:
			answer(f, idx, 0)
		}
	}
}

@(private = "file")
header_value :: proc(r: Fake_Request, name: string) -> string {
	prefix := fmt.tprintf("%s: ", name)
	for h in r.headers {
		if strings.has_prefix(h, prefix) {
			return h[len(prefix):]
		}
	}
	return ""
}

// The session token and accountHash of every identify request, in order.
@(private = "file")
identifies :: proc(f: ^Fake) -> (tokens: [dynamic]string, hashes: [dynamic]string) {
	tokens = make([dynamic]string, context.temp_allocator)
	hashes = make([dynamic]string, context.temp_allocator)
	for r in f.requests {
		if !is_identify(r) {
			continue
		}
		append(&tokens, header_value(r, "X-Session-Token"))
		parsed, err := json.parse_string(r.body, allocator = context.temp_allocator)
		obj, _ := parsed.(json.Object)
		hash, _ := obj["accountHash"].(json.String)
		append(&hashes, err == nil ? string(hash) : "")
	}
	return
}

@(private = "file")
stored_hash :: proc(f: ^Fake) -> string {
	return load_identity(storage_in(f), context.temp_allocator).identity_hash
}

// --- Conformance 1: the hash ----------------------------------------------------

@(test)
test_identify_every_accept_vector_hashes_to_its_wire :: proc(t: ^testing.T) {
	v := load_vectors(t)
	checked := 0
	for c in v.accept {
		obj, _ := c.(json.Object)
		// A whole number cannot be passed where a string is expected.
		if b, _ := obj["integer"].(json.Boolean); b {
			continue
		}
		id, _ := obj["accountId"].(json.String)
		want, _ := obj["wire"].(json.String)
		player, _ := obj["playerId"].(json.String)
		note, _ := obj["note"].(json.String)
		testing.expectf(t, identify_refusal(string(id)) == "", "%s: refused", note)
		got := identify_account_hash(string(id), v.salt, context.temp_allocator)
		testing.expectf(t, got == string(want), "%s: got %s want %s", note, got, want)
		testing.expectf(t, strings.concatenate({"px_", got[:32]}, context.temp_allocator) == string(player), "%s: player id", note)
		checked += 1
	}
	testing.expect_value(t, checked, len(v.accept) - 1)
}

@(test)
test_identify_two_salts_give_two_wires :: proc(t: ^testing.T) {
	v := load_vectors(t)
	differ, _ := v.root["salts_differ"].(json.Object)
	id, _ := differ["accountId"].(json.String)
	salt_a, _ := differ["salt_a"].(json.String)
	salt_b, _ := differ["salt_b"].(json.String)
	wire_a, _ := differ["wire_a"].(json.String)
	wire_b, _ := differ["wire_b"].(json.String)
	testing.expect_value(t, identify_account_hash(string(id), string(salt_a), context.temp_allocator), string(wire_a))
	testing.expect_value(t, identify_account_hash(string(id), string(salt_b), context.temp_allocator), string(wire_b))
	testing.expect(t, wire_a != wire_b)
}

// --- Conformance 2: refusals ----------------------------------------------------

@(test)
test_identify_every_refuse_vector_is_refused :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{callbacks = recorder_callbacks(&rec)})
	s := server_make(v, "s")
	serve(&f, cl, &s)
	device := strings.clone(device_id(cl), context.temp_allocator)
	checked := 0
	for c in v.refuse {
		obj, _ := c.(json.Object)
		// null and a fraction cannot be passed as an Odin string.
		id, is_str := obj["accountId"].(json.String)
		if !is_str {
			continue
		}
		reason, _ := obj["reason"].(json.String)
		testing.expect_value(t, identify_refusal(string(id)), string(reason))
		testing.expect(t, !identify(cl, string(id)))
		checked += 1
	}
	serve(&f, cl, &s)
	testing.expect_value(t, checked, len(v.refuse) - 2)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 0)
	testing.expect_value(t, stored_hash(&f), "")
	testing.expect(t, !is_identified(cl))
	testing.expect_value(t, device_id(cl), device)
	warned := 0
	for line in rec.logs {
		if strings.contains(line, "identify refused (looks_like_email)") {
			warned += 1
		}
	}
	testing.expect_value(t, warned, 4) // one warning per refused call
	close_client(cl)
}

// --- Conformance 3: the sequence ------------------------------------------------

@(test)
test_identify_the_sequence_holds :: proc(t: ^testing.T) {
	v := load_vectors(t)
	testing.expect_value(t, len(v.sequence), 12)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "S1")

	// 0. Before any session: held in memory only, nothing sent or stored.
	cl := fake_client(t, &f, Config{})
	testing.expect(t, identify(cl, "u1"))
	testing.expect(t, cl.identity_held != "")
	testing.expect_value(t, stored_hash(&f), "")
	testing.expect_value(t, len(f.requests), 0)

	// 1. S1 opens with the salt: hashed, stored, sent once.
	serve(&f, cl, &s)
	tokens, hashes := identifies(&f)
	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, tokens[0], "S1_1")
	testing.expect_value(t, hashes[0], sent_hash(v, 1))
	testing.expect_value(t, stored_hash(&f), sent_hash(v, 1))
	testing.expect_value(t, load_identity(storage_in(&f), context.temp_allocator).identity_salt, v.salt)
	testing.expect_value(t, cl.identity_held, "")

	// 2. The same account again: nothing.
	device1 := strings.clone(device_id(cl), context.temp_allocator)
	testing.expect(t, identify(cl, "u1"))
	track(cl, "a")
	flush(cl)
	serve(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, device_id(cl), device1)

	// 3. Relaunch: S2 identifies with no call.
	close_client(cl)
	s.token_prefix = "S2"
	s.sessions = 0
	cl = fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	tokens, hashes = identifies(&f)
	testing.expect_value(t, len(tokens), 2)
	testing.expect_value(t, tokens[1], "S2_1")
	testing.expect_value(t, hashes[1], sent_hash(v, 3))

	// 4. An email: refused, nothing changes.
	device2 := strings.clone(device_id(cl), context.temp_allocator)
	testing.expect(t, !identify(cl, "player@example.com"))
	serve(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 2)
	testing.expect_value(t, stored_hash(&f), sent_hash(v, 3))
	testing.expect_value(t, device_id(cl), device2)

	// 5. Another account: fresh device and session, then sent there.
	testing.expect(t, identify(cl, "u2"))
	serve(&f, cl, &s)
	testing.expect(t, device_id(cl) != device2)
	tokens, hashes = identifies(&f)
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[2], "S2_2")
	testing.expect_value(t, hashes[2], sent_hash(v, 5))
	testing.expect_value(t, stored_hash(&f), sent_hash(v, 5))

	// 6. reset_identity: fresh device, nothing stored or sent.
	device3 := strings.clone(device_id(cl), context.temp_allocator)
	reset_identity(cl)
	testing.expect(t, device_id(cl) != device3)
	testing.expect_value(t, stored_hash(&f), "")
	testing.expect(t, !is_identified(cl))
	track(cl, "b")
	flush(cl)
	serve(&f, cl, &s)
	testing.expect_value(t, count_requests(&f, "/session"), 4)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 3)

	// 7. reset_identity with nothing stored: nothing at all.
	device4 := strings.clone(device_id(cl), context.temp_allocator)
	reset_identity(cl)
	testing.expect_value(t, device_id(cl), device4)
	serve(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 3)

	// 8. needs_funds: kept, sent once, never in a loop.
	s.identify_status = 429
	s.identify_body = `{"error":"quota_exceeded","reason":"needs_funds"}`
	testing.expect(t, identify(cl, "u3"))
	serve(&f, cl, &s)
	tokens, hashes = identifies(&f)
	testing.expect_value(t, len(tokens), 4)
	testing.expect_value(t, tokens[3], "S2_3")
	testing.expect_value(t, hashes[3], sent_hash(v, 8))
	testing.expect_value(t, stored_hash(&f), sent_hash(v, 8))
	for _ in 0 ..< 3 {
		track(cl, "c")
		flush(cl)
		f.now += 60_000
		serve(&f, cl, &s)
	}
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 4)
	// Retried at the next session.
	close_client(cl)
	s.identify_status = 200
	s.token_prefix = "S2b"
	s.sessions = 0
	cl = fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	tokens, hashes = identifies(&f)
	testing.expect_value(t, len(tokens), 5)
	testing.expect_value(t, hashes[4], sent_hash(v, 8))

	// 9. Another game's salt: deleted, never sent.
	close_client(cl)
	differ, _ := v.root["salts_differ"].(json.Object)
	salt_b, _ := differ["salt_b"].(json.String)
	s.salt = string(salt_b)
	cl = fake_client(t, &f, Config{})
	track(cl, "d")
	serve(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 5)
	testing.expect_value(t, stored_hash(&f), "")
	testing.expect(t, !is_identified(cl))

	// 10. No salt in the answer: unavailable this launch, the held id dropped.
	close_client(cl)
	s.salt = ""
	cl = fake_client(t, &f, Config{})
	testing.expect(t, identify(cl, "u4"))
	track(cl, "e")
	serve(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 5)
	testing.expect_value(t, stored_hash(&f), "")
	testing.expect_value(t, cl.identity_held, "")
	testing.expect(t, !is_identified(cl))

	// 11. Opt-out deletes the stored identity.
	close_client(cl)
	s.salt = v.salt
	cl = fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	testing.expect(t, identify(cl, "u5"))
	serve(&f, cl, &s)
	testing.expect(t, stored_hash(&f) != "")
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 6)
	set_tracking_enabled(cl, false)
	testing.expect_value(t, stored_hash(&f), "")
	testing.expect(t, !is_identified(cl))
	close_client(cl)
}

@(test)
test_identify_reset_device_id_keeps_the_identity :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	identify(cl, "u1")
	serve(&f, cl, &s)
	kept := strings.clone(stored_hash(&f), context.temp_allocator)
	testing.expect(t, kept != "")
	reset_device_id(cl)
	track(cl, "a")
	serve(&f, cl, &s)
	testing.expect_value(t, stored_hash(&f), kept)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 2)
	testing.expect_value(t, tokens[1], "s_2")
	close_client(cl)
}

@(test)
test_identify_answers_that_stop_for_the_launch :: proc(t: ^testing.T) {
	v := load_vectors(t)
	bodies := [2]string{`{"error":"not_found"}`, `{"error":"invalid_account_hash"}`}
	statuses := [2]int{404, 400}
	for i in 0 ..< 2 {
		f: Fake
		fake_init(&f)
		defer fake_destroy(&f)
		s := server_make(v, "s")
		s.identify_status = statuses[i]
		s.identify_body = bodies[i]
		cl := fake_client(t, &f, Config{})
		serve(&f, cl, &s)
		identify(cl, "u1")
		serve(&f, cl, &s)
		reset_device_id(cl)
		track(cl, "a")
		serve(&f, cl, &s)
		testing.expect_value(t, count_requests(&f, "/session"), 2)
		tokens, _ := identifies(&f)
		testing.expectf(t, len(tokens) == 1, "%d: %d sends", statuses[i], len(tokens))
		testing.expect(t, stored_hash(&f) != "")
		close_client(cl)
	}
}

@(test)
test_identify_other_answers_wait_for_the_next_session :: proc(t: ^testing.T) {
	v := load_vectors(t)
	statuses := [7]int{400, 409, 409, 429, 429, 503, 0}
	bodies := [7]string{`{"error":"no_session"}`, `{"error":"session_taken"}`, `{"error":"synthetic_session"}`, `{"error":"identify_limited"}`, `{"error":"rate_limited"}`, `{"error":"unavailable"}`, ``}
	for i in 0 ..< len(statuses) {
		f: Fake
		fake_init(&f)
		defer fake_destroy(&f)
		s := server_make(v, "s")
		s.identify_status = statuses[i]
		s.identify_body = bodies[i]
		cl := fake_client(t, &f, Config{})
		serve(&f, cl, &s)
		identify(cl, "u1")
		track(cl, "a")
		flush(cl)
		serve(&f, cl, &s)
		track(cl, "b")
		flush(cl)
		serve(&f, cl, &s)
		tokens, _ := identifies(&f)
		testing.expectf(t, len(tokens) == 1, "no loop on %s", bodies[i])
		reset_device_id(cl)
		track(cl, "c")
		serve(&f, cl, &s)
		tokens, _ = identifies(&f)
		testing.expectf(t, len(tokens) == 2, "next session on %s", bodies[i])
		testing.expect(t, stored_hash(&f) != "")
		close_client(cl)
	}
}

@(test)
test_identify_a_late_200_after_reset_identity_changes_nothing :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	s.hold_identify = true
	cl := fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	identify(cl, "u1")
	serve(&f, cl, &s)
	held := -1
	for r, i in f.requests {
		if is_identify(r) && !r.answered {
			held = i
		}
	}
	testing.expect(t, held >= 0)
	reset_identity(cl)
	track(cl, "a")
	serve(&f, cl, &s)
	testing.expect_value(t, count_requests(&f, "/session"), 2)
	answer(&f, held, 200, `{"playerId":"px_x","linked":true,"verified":false,"repeat":false}`)
	testing.expect(t, !is_identified(cl))
	testing.expect_value(t, stored_hash(&f), "")
	s.hold_identify = false
	identify(cl, "u2")
	serve(&f, cl, &s)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 2)
	testing.expect_value(t, tokens[1], "s_2")
	close_client(cl)
}

// --- Conformance 4: the request -------------------------------------------------

@(test)
test_identify_request_carries_the_key_the_session_and_only_the_hash :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	identify(cl, "12345")
	serve(&f, cl, &s)
	r: Fake_Request
	n := 0
	for req in f.requests {
		if is_identify(req) {
			r = req
			n += 1
		}
	}
	testing.expect_value(t, n, 1)
	testing.expect_value(t, header_value(r, "X-API-Key"), "gt_live_test")
	testing.expect_value(t, header_value(r, "X-Session-Token"), "s_1")
	testing.expect_value(t, header_value(r, "Content-Type"), "application/json")
	first, _ := v.accept[0].(json.Object)
	wire, _ := first["wire"].(json.String)
	testing.expect_value(t, r.body, fmt.tprintf(`{{"accountHash":"%s"}}`, wire))
	testing.expect(t, !strings.contains(r.body, device_id(cl)))
	data, _ := os.read_entire_file(storage_in(&f), context.temp_allocator)
	testing.expect(t, !strings.contains(string(data), `"12345"`))
	// Never in the event queue.
	for e in cl.core.queue {
		testing.expect(t, !strings.contains(e.name, "identify"))
	}
	close_client(cl)
}

// --- Conformance 5: nothing without a key or before consent -----------------------

@(test)
test_identify_inert_without_a_key :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	transport := Transport{user = &f, send = fake_send, now = fake_now, idle = fake_idle}
	cl, _ := create_with_transport(Config{optional = true, storage_path = storage_in(&f)}, transport, false)
	f.client = cl
	testing.expect(t, identify(cl, "u1"))
	testing.expect(t, !identify(cl, "a@b"))
	for _ in 0 ..< 5 {
		tick(cl)
	}
	testing.expect_value(t, len(f.requests), 0)
	testing.expect(t, !os.exists(storage_in(&f)))
	testing.expect(t, is_identified(cl))
	reset_identity(cl)
	testing.expect(t, !is_identified(cl))
	testing.expect(t, !os.exists(storage_in(&f)))
	close_client(cl)
}

@(test)
test_identify_opt_in_holds_the_id_until_the_yes :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{consent = .Opt_In})
	testing.expect(t, identify(cl, "u1"))
	serve(&f, cl, &s)
	testing.expect_value(t, len(f.requests), 0)
	testing.expect(t, !os.exists(storage_in(&f)))
	testing.expect(t, cl.identity_held != "")
	set_tracking_enabled(cl, true)
	serve(&f, cl, &s)
	_, hashes := identifies(&f)
	testing.expect_value(t, len(hashes), 1)
	testing.expect_value(t, hashes[0], sent_hash(v, 1))
	testing.expect_value(t, stored_hash(&f), sent_hash(v, 1))
	testing.expect_value(t, cl.identity_held, "")
	close_client(cl)
}

@(test)
test_identify_withdrawing_consent_drops_a_held_id :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{consent = .Opt_In})
	identify(cl, "u1")
	set_tracking_enabled(cl, false)
	set_tracking_enabled(cl, true)
	serve(&f, cl, &s)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 0)
	testing.expect_value(t, stored_hash(&f), "")
	close_client(cl)
}

@(test)
test_identify_a_playtest_run_never_stores_or_sends :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{playtest_token = "pt_token", playtest_run_id = "run_7"})
	testing.expect(t, identify(cl, "u1"))
	track(cl, "a")
	serve(&f, cl, &s)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 0)
	testing.expect_value(t, stored_hash(&f), "")
	close_client(cl)
}

@(test)
test_identify_nil_client_is_safe :: proc(t: ^testing.T) {
	testing.expect(t, !identify(nil, "u1"))
	reset_identity(nil)
	testing.expect(t, !is_identified(nil))
}

// --- Flow review fixes ------------------------------------------------------------

@(private = "file")
hmac_of :: proc(id, salt: string) -> string {
	return identify_account_hash(id, salt, context.temp_allocator)
}

@(private = "file")
salt_b :: proc(v: Vectors) -> string {
	differ, _ := v.root["salts_differ"].(json.Object)
	b, _ := differ["salt_b"].(json.String)
	return string(b)
}

// F1: no eager session during a Retry-After hold; the next ordinary session carries it.
@(test)
test_identify_no_eager_session_during_a_retry_after :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	s.batch_status = 429
	s.batch_retry_ms = 120_000
	track(cl, "a")
	flush(cl)
	serve(&f, cl, &s)
	testing.expect_value(t, count_requests(&f, "/session"), 1)
	s.batch_status = 0
	reset_device_id(cl) // the session is gone; the hold is not
	identify(cl, "u1")
	serve(&f, cl, &s)
	f.now += 121_000
	serve(&f, cl, &s)
	testing.expect_value(t, count_requests(&f, "/session"), 1)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 0)
	track(cl, "b")
	flush(cl)
	serve(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 1)
	if len(tokens) == 1 {
		testing.expect_value(t, tokens[0], "s_2")
	}
	close_client(cl)
}

// F2: the same id before the salt is held and hashed under the salt that arrives.
@(test)
test_identify_same_id_before_the_salt_uses_the_new_salt :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "A")
	cl := fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	identify(cl, "u1")
	serve(&f, cl, &s)
	close_client(cl)
	other := salt_b(v)
	s.salt = other
	s.token_prefix = "B"
	cl = fake_client(t, &f, Config{})
	testing.expect(t, identify(cl, "u1"))
	serve(&f, cl, &s)
	_, hashes := identifies(&f)
	testing.expect_value(t, hashes[len(hashes) - 1], hmac_of("u1", other))
	saved := load_identity(storage_in(&f), context.temp_allocator)
	testing.expect_value(t, saved.identity_salt, other)
	testing.expect_value(t, saved.identity_hash, hmac_of("u1", other))
	close_client(cl)
}

// F3: collection or consent back on inside an open session sends the identify.
@(test)
test_identify_collection_back_on_sends :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	set_enabled(cl, false)
	testing.expect(t, identify(cl, "u1"))
	serve(&f, cl, &s)
	tokens, hashes := identifies(&f)
	testing.expect_value(t, len(tokens), 0)
	set_enabled(cl, true)
	serve(&f, cl, &s)
	tokens, hashes = identifies(&f)
	testing.expect_value(t, len(hashes), 1)
	set_tracking_enabled(cl, false)
	testing.expect(t, identify(cl, "u2"))
	set_tracking_enabled(cl, true)
	serve(&f, cl, &s)
	tokens, hashes = identifies(&f)
	testing.expect_value(t, hashes[len(hashes) - 1], hmac_of("u2", v.salt))
	close_client(cl)
}

@(private = "file")
seed_identity :: proc(f: ^Fake, v: Vectors) {
	os.make_directory_all(f.dir)
	save_identity(storage_in(f), Saved_Identity{device_id = "dev_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", tracking_enabled = true, identity_salt = v.salt, identity_hash = hmac_of("u1", v.salt)})
}

// F4: before consent, a stored identity is deleted by a decline and by reset_identity.
@(test)
test_identify_before_consent_a_stored_identity_is_deleted :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	seed_identity(&f, v)
	cl := fake_client(t, &f, Config{consent = .Opt_In})
	set_tracking_enabled(cl, false)
	testing.expect_value(t, stored_hash(&f), "")
	close_client(cl)

	seed_identity(&f, v)
	cl = fake_client(t, &f, Config{consent = .Opt_In})
	testing.expect(t, is_identified(cl))
	reset_identity(cl)
	testing.expect_value(t, stored_hash(&f), "")
	testing.expect(t, device_id(cl) != "dev_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	set_tracking_enabled(cl, true)
	track(cl, "a")
	serve(&f, cl, &s)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 0)
	close_client(cl)
}

// F6: two quick calls before the salt: the last one wins.
@(test)
test_identify_last_call_before_the_salt_wins :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	cl := fake_client(t, &f, Config{})
	identify(cl, "u1")
	identify(cl, "u2")
	serve(&f, cl, &s)
	_, hashes := identifies(&f)
	testing.expect_value(t, len(hashes), 1)
	testing.expect_value(t, hashes[0], hmac_of("u2", v.salt))
	testing.expect_value(t, stored_hash(&f), hmac_of("u2", v.salt))
	close_client(cl)
}

// F7: sent on the token the session answer just returned.
@(test)
test_identify_sent_on_the_fresh_token :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	s.next_session_body = fmt.tprintf(`{{"token":"fresh","expiresAt":%d,"identify":{{"salt":"%s"}}}}`, f.now / 1000 - 10, v.salt)
	cl := fake_client(t, &f, Config{disable_lifecycle_events = true})
	identify(cl, "u1")
	serve(&f, cl, &s)
	tokens, _ := identifies(&f)
	testing.expect(t, len(tokens) >= 1)
	if len(tokens) >= 1 {
		testing.expect_value(t, tokens[0], "fresh")
	}
	close_client(cl)
}

// F8: a second no_session in a row stops until a sign-out; other answers reset the count.
@(test)
test_identify_second_no_session_stops :: proc(t: ^testing.T) {
	v := load_vectors(t)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	s := server_make(v, "s")
	no_session := `{"error":"no_session"}`
	s.identify_status = 400
	s.identify_body = no_session
	cl := fake_client(t, &f, Config{})
	serve(&f, cl, &s)
	identify(cl, "u1")
	serve(&f, cl, &s)
	next_session :: proc(f: ^Fake, cl: ^Client, s: ^Server) {
		reset_device_id(cl)
		track(cl, "x")
		flush(cl)
		serve(f, cl, s)
	}
	next_session(&f, cl, &s)
	tokens, _ := identifies(&f)
	testing.expect_value(t, len(tokens), 2)
	next_session(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 2)

	reset_identity(cl) // a sign-out starts over
	identify(cl, "u2")
	serve(&f, cl, &s)
	s.identify_status = 503
	s.identify_body = `{"error":"unavailable"}`
	next_session(&f, cl, &s)
	s.identify_status = 400
	s.identify_body = no_session
	next_session(&f, cl, &s)
	next_session(&f, cl, &s)
	tokens, _ = identifies(&f)
	testing.expect_value(t, len(tokens), 6)
	close_client(cl)
}
