// core_test.odin - unit tests for the pure protocol state machine.
//
// No network and no clock: time is a plain integer these tests advance by
// hand, and server answers are Core_Response values fed straight into the
// core. Run with `odin test ravensight`.

package ravensight

import "core:fmt"
import "core:strings"
import "core:testing"

T0: i64 : 1_000_000

// Boots a core through the settings check and (optionally) a session, the
// way client.odin would.
boot :: proc(t: ^testing.T, c: ^Core, now: i64, with_session := true) {
	req, ok := core_next(c, now)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Settings)
	sig := core_on_response(c, Core_Response{status = 200, has_tracking_enabled = true, tracking_enabled = true}, now)
	testing.expect(t, !sig.tracking_disabled)

	if with_session {
		track_n(c, 1, now, "game_started")
		open_session(t, c, now)
	}
}

open_session :: proc(t: ^testing.T, c: ^Core, now: i64) {
	req, ok := core_next(c, now)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Session)
	sig := core_on_response(c, Core_Response{status = 201, token = "tok_1", expires_in_ms = 86_400_000}, now)
	testing.expect(t, sig.session_ready)
}

track_n :: proc(c: ^Core, n: int, now: i64, prefix := "e") {
	for i in 0 ..< n {
		name := fmt.tprintf("%s%d", prefix, i)
		core_track(c, name, `{"i":1}`, now)
	}
}

// Expects the next request to be a batch of `expect_len` events and answers
// it with `res`.
step_batch :: proc(t: ^testing.T, c: ^Core, now: i64, expect_len: int, res: Core_Response) -> Signals {
	req, ok := core_next(c, now)
	testing.expect(t, ok, "expected a batch request")
	testing.expect_value(t, req.kind, Request_Kind.Batch)
	testing.expect_value(t, req.batch_len, expect_len)
	delete(req.body)
	return core_on_response(c, res, now)
}

expect_no_request :: proc(t: ^testing.T, c: ^Core, now: i64, loc := #caller_location) {
	req, ok := core_next(c, now)
	if ok {
		delete(req.body)
	}
	testing.expect(t, !ok, "expected no request", loc = loc)
}

@(test)
test_queue_cap_drops_oldest :: proc(t: ^testing.T) {
	c := core_make(max_queue = 500)
	defer core_destroy(&c)

	track_n(&c, 510, T0)
	testing.expect_value(t, len(c.queue), 500)
	testing.expect_value(t, c.queue[0].name, "e10")
	testing.expect_value(t, c.queue[499].name, "e509")
	testing.expect_value(t, c.stats.dropped, 10)
}

@(test)
test_batches_of_50_drain_queue :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 120, T0)
	open_session(t, &c, T0)
	core_request_flush(&c)

	sig := step_batch(t, &c, T0, 50, Core_Response{status = 202})
	testing.expect_value(t, sig.events_flushed, 50)
	sig = step_batch(t, &c, T0, 50, Core_Response{status = 202})
	testing.expect_value(t, sig.events_flushed, 50)
	sig = step_batch(t, &c, T0, 20, Core_Response{status = 202})
	testing.expect_value(t, sig.events_flushed, 20)

	testing.expect_value(t, len(c.queue), 0)
	testing.expect_value(t, c.stats.sent, 120)
	expect_no_request(t, &c, T0)
}

@(test)
test_401_requeues_batch_and_reauths :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 60, T0)
	open_session(t, &c, T0)
	core_request_flush(&c)

	first_name := strings.clone(c.queue[0].name, context.temp_allocator)
	step_batch(t, &c, T0, 50, Core_Response{status = 401})

	// Nothing was lost and the session is gone.
	testing.expect_value(t, len(c.queue), 60)
	testing.expect(t, !core_is_session_valid(&c, T0))

	// A new session opens immediately (no backoff) and the same batch is
	// re-sent, starting with the same first event.
	open_session(t, &c, T0)
	testing.expect_value(t, c.queue[0].name, first_name)
	sig := step_batch(t, &c, T0, 50, Core_Response{status = 202})
	testing.expect_value(t, sig.events_flushed, 50)
	testing.expect_value(t, len(c.queue), 10)
}

@(test)
test_repeated_401_backs_off :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 10, T0)
	open_session(t, &c, T0)
	core_request_flush(&c)

	// Three consecutive 401s on freshly issued tokens: the third one must
	// stop the hot re-auth loop.
	for _ in 0 ..< 2 {
		step_batch(t, &c, T0, 10, Core_Response{status = 401})
		open_session(t, &c, T0)
	}
	step_batch(t, &c, T0, 10, Core_Response{status = 401})
	testing.expect(t, c.next_attempt_at_ms > T0, "expected backoff after repeated 401s")
	expect_no_request(t, &c, T0)

	// After the backoff expires the cycle resumes with a session request.
	later := c.next_attempt_at_ms
	req, ok := core_next(&c, later)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Session)
}

@(test)
test_429_honors_retry_after :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0)
	track_n(&c, 5, T0)
	core_request_flush(&c)

	sig := step_batch(t, &c, T0, 6, Core_Response{status = 429, retry_after_ms = 7000, error_code = "rate_limited"})
	testing.expect(t, sig.flush_failed)
	testing.expect_value(t, sig.reason, "rate_limited")

	expect_no_request(t, &c, T0+6999)
	req, ok := core_next(&c, T0+7000)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Batch)
	delete(req.body)

	// Honoring Retry-After must not advance the exponential schedule: the
	// next headerless failure still waits the base 10s.
	core_on_response(&c, Core_Response{status = 429}, T0+7000)
	testing.expect_value(t, c.next_attempt_at_ms, T0+7000+DEFAULT_RETRY_MS)
}

@(test)
test_exponential_backoff_10s_to_300s :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0)
	track_n(&c, 3, T0)
	core_request_flush(&c)

	now := T0
	expected: i64 = DEFAULT_RETRY_MS
	for _ in 0 ..< 8 {
		sig := step_batch(t, &c, now, 4, Core_Response{status = 500})
		testing.expect(t, sig.flush_failed)
		testing.expect_value(t, c.next_attempt_at_ms - now, expected)
		expect_no_request(t, &c, c.next_attempt_at_ms - 1)
		now = c.next_attempt_at_ms
		expected = min(expected * 2, MAX_BACKOFF_MS)
	}
	// 10, 20, 40, 80, 160, 320 -> capped: the schedule must have hit 300s.
	testing.expect_value(t, c.backoff_ms, i64(MAX_BACKOFF_MS))
}

@(test)
test_backoff_resets_on_success :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0)
	track_n(&c, 3, T0)
	core_request_flush(&c)

	now := T0
	for _ in 0 ..< 3 {
		step_batch(t, &c, now, 4, Core_Response{status = 500})
		now = c.next_attempt_at_ms
	}
	testing.expect_value(t, c.backoff_ms, i64(80_000))

	step_batch(t, &c, now, 4, Core_Response{status = 202})
	testing.expect_value(t, c.backoff_ms, i64(DEFAULT_RETRY_MS))
	testing.expect_value(t, c.next_attempt_at_ms, i64(0))
}

@(test)
test_400_splits_batch_down_to_one_then_drops :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 50, T0)
	open_session(t, &c, T0)
	core_request_flush(&c)

	// 50 -> 25 -> 12 -> 6 -> 3 -> 1, all rejected with 400, no backoff.
	sizes := [?]int{50, 25, 12, 6, 3, 1}
	for size in sizes {
		sig := step_batch(t, &c, T0, size, Core_Response{status = 400})
		testing.expect_value(t, c.next_attempt_at_ms, i64(0))
		if size == 1 {
			testing.expect(t, sig.event_dropped)
		} else {
			testing.expect(t, !sig.event_dropped)
		}
	}

	// The poison event is gone, nothing else was lost, and the batch size
	// snaps back to the full 50.
	testing.expect_value(t, len(c.queue), 49)
	testing.expect_value(t, c.queue[0].name, "e1")
	testing.expect_value(t, c.stats.dropped, 1)
	sig := step_batch(t, &c, T0, 49, Core_Response{status = 202})
	testing.expect_value(t, sig.events_flushed, 49)
}

@(test)
test_kill_switch_disables_and_clears :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	track_n(&c, 5, T0) // queued before the settings answer arrives

	req, ok := core_next(&c, T0)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Settings)
	sig := core_on_response(&c, Core_Response{status = 200, has_tracking_enabled = true, tracking_enabled = false}, T0)

	testing.expect(t, sig.tracking_disabled)
	testing.expect_value(t, len(c.queue), 0)
	testing.expect(t, !core_track(&c, "later", "", T0))
	expect_no_request(t, &c, T0+100_000)
}

@(test)
test_settings_failure_assumes_enabled :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)

	req, ok := core_next(&c, T0)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Settings)
	sig := core_on_response(&c, Core_Response{status = 0}, T0)
	testing.expect(t, !sig.tracking_disabled)
	testing.expect(t, c.tracking_enabled)
	testing.expect(t, core_track(&c, "e", "", T0))
}

@(test)
test_session_expiry_resolution :: proc(t: ^testing.T) {
	// expiresAt (absolute) wins over expiresIn.
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 1, T0)

	req, _ := core_next(&c, T0)
	testing.expect_value(t, req.kind, Request_Kind.Session)
	core_on_response(&c, Core_Response{status = 201, token = "tok", expires_at_ms = T0 + 50_000, expires_in_ms = 999_000}, T0)
	testing.expect_value(t, c.session_expires_at_ms, T0+50_000)

	// Within the expiry skew the session already counts as invalid.
	testing.expect(t, core_is_session_valid(&c, T0))
	testing.expect(t, !core_is_session_valid(&c, T0+45_000))

	// Neither field present: the 24h default applies.
	c2 := core_make()
	defer core_destroy(&c2)
	boot(t, &c2, T0, with_session = false)
	track_n(&c2, 1, T0)
	req2, _ := core_next(&c2, T0)
	testing.expect_value(t, req2.kind, Request_Kind.Session)
	core_on_response(&c2, Core_Response{status = 201, token = "tok"}, T0)
	testing.expect_value(t, c2.session_expires_at_ms, T0+DEFAULT_SESSION_TTL_MS)
}

@(test)
test_session_429_honors_retry_after :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 1, T0)

	req, _ := core_next(&c, T0)
	testing.expect_value(t, req.kind, Request_Kind.Session)
	sig := core_on_response(&c, Core_Response{status = 429, retry_after_ms = 30_000}, T0)
	testing.expect(t, sig.session_failed)
	testing.expect_value(t, sig.reason, "rate_limited")

	expect_no_request(t, &c, T0+29_999)
	req2, ok := core_next(&c, T0+30_000)
	testing.expect(t, ok)
	testing.expect_value(t, req2.kind, Request_Kind.Session)
}

@(test)
test_flush_timer_five_seconds :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 1, T0)
	open_session(t, &c, T0)
	track_n(&c, 2, T0, "more")

	// game_started + 2 events queued, but the 5s timer has not fired.
	expect_no_request(t, &c, T0+4_999)
	req, ok := core_next(&c, T0+5_000)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Batch)
	testing.expect_value(t, req.batch_len, 3)
	delete(req.body)
}

@(test)
test_full_batch_flushes_before_timer :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 1, T0)
	open_session(t, &c, T0)
	track_n(&c, MAX_BATCH_SIZE, T0)

	// 51 queued >= one full batch: no need to wait for the timer.
	req, ok := core_next(&c, T0+1)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Batch)
	delete(req.body)
}

@(test)
test_force_flush_bypasses_backoff :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0)
	track_n(&c, 2, T0)
	core_request_flush(&c)
	step_batch(t, &c, T0, 3, Core_Response{status = 500})
	expect_no_request(t, &c, T0+1)

	core_force_flush(&c)
	req, ok := core_next(&c, T0+1)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Batch)
	delete(req.body)
}

@(test)
test_explicit_flush_respects_backoff :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0)
	track_n(&c, 2, T0)
	core_request_flush(&c)
	step_batch(t, &c, T0, 3, Core_Response{status = 500})

	core_request_flush(&c)
	expect_no_request(t, &c, T0+1)
}

@(test)
test_session_opens_as_soon_as_event_is_queued :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	expect_no_request(t, &c, T0) // enabled, but nothing to do yet

	track_n(&c, 1, T0)
	req, ok := core_next(&c, T0)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Session)
}

@(test)
test_set_enabled_false_discards_queue :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0)
	track_n(&c, 7, T0)

	core_set_enabled(&c, false)
	testing.expect_value(t, len(c.queue), 0)
	testing.expect(t, !core_track(&c, "e", "", T0))
	expect_no_request(t, &c, T0+100_000)

	core_set_enabled(&c, true)
	testing.expect(t, core_track(&c, "e", "", T0))
}

@(test)
test_json_string_escaping :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, input, expected: string, loc := #caller_location) {
		b := strings.builder_make(context.temp_allocator)
		write_json_string(&b, input)
		testing.expect_value(t, strings.to_string(b), expected, loc = loc)
	}
	check(t, `plain`, `"plain"`)
	check(t, `say "hi"`, `"say \"hi\""`)
	check(t, `back\slash`, `"back\\slash"`)
	check(t, "line\nbreak", `"line\nbreak"`)
	check(t, "cr\rtab\tdone", `"cr\rtab\tdone"`)
	check(t, "\b\f", `"\b\f"`)
	check(t, "ctl\x01\x1f", "\"ctl\\u0001\\u001f\"")
	check(t, "", `""`)
	check(t, "utf8 snake: ü本", "\"utf8 snake: ü本\"")
}

@(test)
test_batch_body_wire_format :: proc(t: ^testing.T) {
	events := [?]Core_Event{
		{name = "level_up", data_json = `{"level":3}`, timestamp_s = 1700000001},
		{name = `weird "name"`, data_json = "", timestamp_s = 1700000002},
	}
	body := build_batch_body(events[:], context.temp_allocator)
	expected := `{"events":[` +
		`{"event":"level_up","data":{"level":3},"timestamp":1700000001},` +
		`{"event":"weird \"name\"","data":{},"timestamp":1700000002}]}`
	testing.expect_value(t, body, expected)
}

@(test)
test_normalize_api_url :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, input, expected: string, loc := #caller_location) {
		got := normalize_api_url(input, context.temp_allocator)
		testing.expect_value(t, got, expected, loc = loc)
	}
	check(t, "", "https://api.ravensight.io/api/v1")
	check(t, "https://api.ravensight.io", "https://api.ravensight.io/api/v1")
	check(t, "https://api.ravensight.io/", "https://api.ravensight.io/api/v1")
	check(t, "https://api.ravensight.io/api/v1", "https://api.ravensight.io/api/v1")
	check(t, "https://api.ravensight.io/api/v1/", "https://api.ravensight.io/api/v1")
	check(t, "  https://self.hosted.example  ", "https://self.hosted.example/api/v1")
}

@(test)
test_feedback_wants_session :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	expect_no_request(t, &c, T0)

	// An empty queue normally never opens a session; a pending feedback
	// submission does.
	core_want_session(&c)
	req, ok := core_next(&c, T0)
	testing.expect(t, ok)
	testing.expect_value(t, req.kind, Request_Kind.Session)
	core_on_response(&c, Core_Response{status = 201, token = "tok"}, T0)
	testing.expect(t, !c.session_wanted)
}
