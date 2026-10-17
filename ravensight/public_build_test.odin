// public_build_test.odin - the 0.3.0 public build rules, through the same
// fake transport and fake clock as client_test.odin: an inert client with no
// key, opt-in consent before and after the yes, distribution on the session
// body, the backoff jitter bounds, rs_event_id and the 8,192 byte cap.

package ravensight

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

Blob :: struct {
	blob: string,
}

Level :: struct {
	level: int,
}

// A client created with no ingest key on the fake transport.
inert_client :: proc(t: ^testing.T, f: ^Fake, cfg: Config) -> ^Client {
	cfg := cfg
	cfg.ingest_key = "  "
	if len(cfg.storage_path) == 0 {
		cfg.storage_path = storage_in(f)
	}
	transport := Transport{user = f, send = fake_send, now = fake_now, idle = fake_idle}
	cl, err := create_with_transport(cfg, transport, false)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, cl != nil)
	f.client = cl
	return cl
}

count_logs :: proc(r: ^Recorder, text: string) -> int {
	n := 0
	for l in r.logs {
		if strings.contains(l, text) {
			n += 1
		}
	}
	return n
}

// Every rs_event_id in a batch body, in order.
event_ids_in :: proc(body: string) -> [dynamic]string {
	ids := make([dynamic]string, context.temp_allocator)
	key := `"rs_event_id":"`
	rest := body
	for {
		i := strings.index(rest, key)
		if i < 0 {
			break
		}
		rest = rest[i + len(key):]
		j := strings.index_byte(rest, '"')
		append(&ids, rest[:j])
		rest = rest[j:]
	}
	return ids
}

is_event_id_shape :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 64 {
		return false
	}
	for i in 0 ..< len(id) {
		switch id[i] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

last_batch_body :: proc(f: ^Fake) -> string {
	for i := len(f.requests) - 1; i >= 0; i -= 1 {
		if f.requests[i].path == "/track/batch" {
			return f.requests[i].body
		}
	}
	return ""
}

session_body_of :: proc(f: ^Fake) -> string {
	for r in f.requests {
		if r.path == "/session" {
			return r.body
		}
	}
	return ""
}

@(test)
test_public_no_key_is_inert :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := inert_client(t, &f, Config{callbacks = recorder_callbacks(&rec)})

	testing.expect_value(t, init_reason(cl), Reason.No_Key)
	testing.expect_value(t, reason_string(init_reason(cl)), "no_key")
	testing.expect(t, !is_enabled(cl))
	testing.expect(t, !is_active(cl))
	testing.expect(t, cl.multi == nil) // libcurl never initialized for it
	testing.expect(t, !track(cl, "level_start", Level{level = 1}))
	flush(cl, force = true)
	testing.expect(t, !fetch_suggestions(cl))
	testing.expect(t, !submit_feedback(cl, "hello", "bug", 4))
	set_enabled(cl, false)
	set_enabled(cl, true)
	testing.expect_value(t, reset_device_id(cl), "")
	for _ in 0 ..< 50 {
		f.now += 10_000
		tick(cl)
	}
	testing.expect_value(t, len(f.requests), 0)
	testing.expect_value(t, queue_len(cl), 0)
	testing.expect(t, !os.exists(f.dir)) // no file, not even the folder
	testing.expect_value(t, device_id(cl), "")
	testing.expect_value(t, len(rec.feedback_failed), 1)
	testing.expect_value(t, rec.feedback_failed[0], "no_key")
	testing.expect_value(t, count_logs(&rec, NO_KEY_WARNING), 1)
	shutdown(cl)
	testing.expect_value(t, len(f.requests), 0)
}

@(test)
test_public_no_key_optional_is_silent_and_saves_the_choice :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := inert_client(t, &f, Config{optional = true, callbacks = recorder_callbacks(&rec)})
	testing.expect_value(t, count_logs(&rec, "no ingest_key"), 0)
	set_tracking_enabled(cl, false)
	testing.expect(t, !is_tracking_enabled(cl))
	saved := load_identity(storage_in(&f), context.temp_allocator)
	testing.expect(t, !saved.tracking_enabled) // the choice is saved
	testing.expect_value(t, saved.device_id, "") // but no device id is made
	set_tracking_enabled(cl, true)
	tick(cl)
	testing.expect_value(t, len(f.requests), 0) // and a yes starts nothing
	testing.expect_value(t, init_reason(cl), Reason.No_Key)
	close_client(cl)

	// The real constructor with no key: no error, inert.
	real, err := create(Config{storage_path = storage_in(&f), optional = true})
	testing.expect_value(t, err, Error.None)
	testing.expect(t, real != nil && real.multi == nil)
	testing.expect_value(t, init_reason(real), Reason.No_Key)
	shutdown(real)
}

@(test)
test_public_opt_in_before_the_yes_does_nothing :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{consent = .Opt_In, callbacks = recorder_callbacks(&rec)})
	testing.expect(t, !track(cl, "before_yes"))
	flush(cl, force = true)
	testing.expect(t, !fetch_suggestions(cl))
	for _ in 0 ..< 50 {
		f.now += 10_000
		tick(cl)
	}
	testing.expect_value(t, len(f.requests), 0) // not even the settings check
	testing.expect_value(t, queue_len(cl), 0) // game_started waits for the yes
	testing.expect(t, !os.exists(storage_in(&f))) // no device id saved
	testing.expect_value(t, device_id(cl), "")
	testing.expect_value(t, init_reason(cl), Reason.Disabled)
	testing.expect(t, !is_tracking_enabled(cl))
	testing.expect_value(t, reset_device_id(cl), "")
	testing.expect(t, !os.exists(storage_in(&f)))
	close_client(cl)
}

@(test)
test_public_opt_in_after_the_yes_starts_and_queues :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{consent = .Opt_In})
	testing.expect(t, !track(cl, "before_yes"))
	set_tracking_enabled(cl, true)
	testing.expect(t, len(device_id(cl)) > 0)
	saved := load_identity(storage_in(&f), context.temp_allocator)
	testing.expect(t, saved.opted_in)
	testing.expect_value(t, saved.device_id, device_id(cl))
	testing.expect(t, track(cl, "right_after_yes")) // queued while the check runs
	testing.expect_value(t, queue_len(cl), 2) // game_started and right_after_yes
	tick(cl)
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":true}`)
	tick(cl)
	answer_next(t, &f, "/session", 201, `{"token":"tok_1","expiresIn":86400}`)
	flush(cl)
	tick(cl)
	batch := last_batch_body(&f)
	testing.expect(t, strings.contains(batch, `"event":"game_started"`), batch)
	testing.expect(t, strings.contains(batch, `"event":"right_after_yes"`), batch)
	testing.expect(t, !strings.contains(batch, "before_yes"), batch)
	testing.expect(t, is_enabled(cl))
	close_client(cl)
}

@(test)
test_public_opt_in_revoke_keeps_the_id_and_a_saved_yes_starts :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{consent = .Opt_In, disable_lifecycle_events = true})
	set_tracking_enabled(cl, true)
	id := strings.clone(device_id(cl), context.temp_allocator)
	close_client(cl)

	// The next launch: the saved yes starts at once, with the same id.
	cl = fake_client(t, &f, Config{consent = .Opt_In, disable_lifecycle_events = true})
	testing.expect(t, is_tracking_enabled(cl))
	testing.expect_value(t, device_id(cl), id)
	tick(cl)
	testing.expect_value(t, f.requests[0].path, "/settings")
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":true}`)

	set_tracking_enabled(cl, false)
	saved := load_identity(storage_in(&f), context.temp_allocator)
	testing.expect_value(t, saved.device_id, id) // kept after the no
	testing.expect(t, !saved.opted_in)
	before := len(f.requests)
	testing.expect(t, !track(cl, "after_no"))
	f.now += 1_000_000
	tick(cl)
	testing.expect_value(t, len(f.requests), before)
	testing.expect_value(t, reset_device_id(cl), "")
	testing.expect(t, !os.exists(storage_in(&f))) // forgotten
	close_client(cl)

	// The default mode reads the yes file as "not opted out".
	plain := fake_client(t, &f, Config{})
	testing.expect(t, is_tracking_enabled(plain))
	close_client(plain)
	testing.expect(t, write_tracking_enabled(true, storage_in(&f), .Opt_In))
	testing.expect(t, load_identity(storage_in(&f), context.temp_allocator).opted_in)
}

@(test)
test_public_distribution_on_the_session_body :: proc(t: ^testing.T) {
	check_label :: proc(t: ^testing.T, label: string, want: string, loc := #caller_location) {
		f: Fake
		fake_init(&f)
		defer fake_destroy(&f)
		rec: Recorder
		defer recorder_destroy(&rec)
		cl := fake_client(t, &f, Config{distribution = label, callbacks = recorder_callbacks(&rec)})
		boot_client(t, &f, cl, loc = loc)
		body := session_body_of(&f)
		if len(want) > 0 {
			testing.expect(t, strings.contains(body, fmt.tprintf(`"distribution":"%s"`, want)), body, loc = loc)
		} else {
			testing.expect(t, !strings.contains(body, "distribution"), body, loc = loc)
		}
		bad := len(strings.trim_space(label)) > 0 && len(want) == 0
		testing.expect_value(t, count_logs(&rec, "distribution must be at most 40"), bad ? 1 : 0, loc = loc)
		close_client(cl)
	}
	check_label(t, "  native-demo ", "native-demo")
	forty := strings.repeat("y", 40, context.temp_allocator)
	check_label(t, forty, forty)
	check_label(t, strings.repeat("x", 41, context.temp_allocator), "")
	check_label(t, "line\nbreak", "")
	check_label(t, "del\x7f", "")
	check_label(t, strings.repeat("\U0001F3AE", 21, context.temp_allocator), "") // 42 UTF-16 units
	check_label(t, "", "")

	// A caller who passes only a key gets the 0.2.0 session body.
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	boot_client(t, &f, cl)
	testing.expect_value(t, session_body_of(&f), strings.concatenate({`{"deviceId":"`, device_id(cl), `","gameVersion":"1.0.0","platform":"`, cl.platform, `","sdk":"odin/` + VERSION + `"}`}, context.temp_allocator))
	close_client(cl)
}

@(test)
test_public_backoff_jitter_bounds :: proc(t: ^testing.T) {
	low := core_make()
	defer core_destroy(&low)
	low.random = proc() -> f64 {return 0}
	core_schedule_backoff(&low, T0)
	testing.expect_value(t, low.next_attempt_at_ms - T0, i64(8_000))
	testing.expect_value(t, low.backoff_ms, i64(20_000)) // the doubling is not spread

	high := core_make()
	defer core_destroy(&high)
	high.random = proc() -> f64 {return 1}
	core_schedule_backoff(&high, T0)
	testing.expect_value(t, high.next_attempt_at_ms - T0, i64(12_000))
	for _ in 0 ..< 10 {
		core_schedule_backoff(&high, T0)
	}
	testing.expect_value(t, high.next_attempt_at_ms - T0, i64(MAX_BACKOFF_MS)) // never past the cap

	mid := core_make()
	defer core_destroy(&mid)
	mid.random = proc() -> f64 {return 0.5}
	core_schedule_backoff(&mid, T0)
	testing.expect_value(t, mid.next_attempt_at_ms - T0, i64(10_000))

	// The real source stays inside plus or minus 20 percent.
	spread := core_make()
	defer core_destroy(&spread)
	spread.random = random_unit
	for _ in 0 ..< 500 {
		draw := random_unit()
		testing.expect(t, draw >= 0 && draw < 1)
		core_reset_backoff(&spread)
		core_schedule_backoff(&spread, T0)
		wait := spread.next_attempt_at_ms - T0
		testing.expect(t, wait >= 8_000 && wait <= 12_000)
	}

	// Retry-After is obeyed exactly, whatever the draw.
	ra := core_make()
	defer core_destroy(&ra)
	ra.random = proc() -> f64 {return 0}
	core_apply_retry_after(&ra, Core_Response{retry_after_ms = 30_000}, T0)
	testing.expect_value(t, ra.next_attempt_at_ms - T0, i64(30_000))

	// The client installs a jittering source; a bare core has none.
	bare := core_make()
	defer core_destroy(&bare)
	testing.expect(t, bare.random == nil)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	transport := Transport{user = &f, send = fake_send, now = fake_now, idle = fake_idle}
	cl, _ := create_with_transport(Config{ingest_key = "gt_live_test", storage_path = storage_in(&f)}, transport, false)
	testing.expect(t, cl.core.random != nil)
	close_client(cl)
}

@(test)
test_public_rs_event_id_shape_prefix_and_resend :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	boot_client(t, &f, cl)
	testing.expect(t, track(cl, "a", Level{level = 1}))
	testing.expect(t, track(cl, "b"))
	flush(cl)
	tick(cl)
	first := strings.clone(last_batch_body(&f), context.temp_allocator)
	answer_next(t, &f, "/track/batch", 500, `{"error":"internal_error"}`)
	f.now += DEFAULT_RETRY_MS
	tick(cl)
	resent := last_batch_body(&f)
	ids := event_ids_in(first)
	testing.expect_value(t, len(ids), 3) // game_started, a, b
	again := event_ids_in(resent)
	testing.expect_value(t, len(again), 3)
	for id, i in ids {
		testing.expect_value(t, again[i], id) // a resend carries the same ids
		testing.expect(t, is_event_id_shape(id), id)
		parts := strings.split(id, "-", context.temp_allocator)
		testing.expect_value(t, len(parts), 4)
		testing.expect_value(t, parts[0], device_id(cl)[:16])
		testing.expect_value(t, len(parts[2]), 8)
	}
	testing.expect(t, ids[0] != ids[1] && ids[1] != ids[2])
	testing.expect(t, strings.contains(first, `{"level":1,"rs_event_id":"`), first)
	close_client(cl)

	// A relaunch keeps the per-install prefix and draws a new nonce.
	f2: Fake
	fake_init(&f2)
	defer fake_destroy(&f2)
	one := fake_client(t, &f2, Config{})
	n1 := strings.clone(one.event_nonce, context.temp_allocator)
	p1 := strings.clone(device_id(one)[:16], context.temp_allocator)
	close_client(one)
	two := fake_client(t, &f2, Config{})
	testing.expect_value(t, device_id(two)[:16], p1)
	testing.expect(t, two.event_nonce != n1)
	testing.expect(t, track(two, "x"))
	last := two.core.queue[len(two.core.queue) - 1].data_json
	testing.expect(t, strings.contains(last, fmt.tprintf(`"rs_event_id":"%s-`, p1)), last)
	close_client(two)

	// A playtest id with characters outside the shape is made safe.
	f3: Fake
	fake_init(&f3)
	defer fake_destroy(&f3)
	pt := fake_client(t, &f3, Config{playtest_token = "ptk", playtest_run_id = "run.with spaces"})
	testing.expect(t, track(pt, "p"))
	pids := event_ids_in(pt.core.queue[len(pt.core.queue) - 1].data_json)
	testing.expect_value(t, len(pids), 1)
	testing.expect(t, is_event_id_shape(pids[0]), pids[0])
	close_client(pt)
}

@(test)
test_public_event_over_8kb_is_dropped :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{disable_lifecycle_events = true, callbacks = recorder_callbacks(&rec)})
	testing.expect(t, !track(cl, "huge", Blob{blob = strings.repeat("x", 8200, context.temp_allocator)}))
	testing.expect(t, !track(cl, "huge_again", Blob{blob = strings.repeat("x", 9000, context.temp_allocator)}))
	testing.expect_value(t, queue_len(cl), 0)
	testing.expect_value(t, len(rec.flush_failed), 2)
	if len(rec.flush_failed) == 2 {
		testing.expect_value(t, rec.flush_failed[0], "event_too_large")
	}
	testing.expect_value(t, stats(cl).dropped, 2)
	testing.expect_value(t, count_logs(&rec, "larger than 8192 bytes"), 1)
	testing.expect(t, track(cl, "fits", Blob{blob = strings.repeat("x", 8000, context.temp_allocator)}))
	testing.expect_value(t, queue_len(cl), 1)
	close_client(cl)
}

@(test)
test_public_key_only_client_writes_what_0_2_0_wrote :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	data, err := os.read_entire_file(storage_in(&f), context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), strings.concatenate({`{"deviceId":"`, device_id(cl), `","trackingEnabled":true}`}, context.temp_allocator))
	close_client(cl)
}
