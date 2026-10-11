// client_test.odin - tests for the public API through a fake transport.
//
// The client normally talks to libcurl and the wall clock. These tests
// install a fake through the transport seam instead: every request is
// recorded with its URL, headers and body, nothing touches the network,
// and the test answers each request by hand with finish_transfer(). Time
// is a plain integer the test advances. The storage file is real, in a
// fresh temporary folder per test.

package ravensight

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

Fake_Request :: struct {
	path:     string, // owned; the URL after the /api/v1 base
	body:     string, // owned
	headers:  [dynamic]string, // owned
	t:        ^Transfer,
	answered: bool,
}

Fake :: struct {
	now:      i64,
	requests: [dynamic]Fake_Request,
	client:   ^Client,
	// Answers anything open while shutdown() waits, when set.
	auto:     proc(path: string) -> (status: int, body: string),
	dir:      string, // owned temporary folder for the storage file
}

Recorder :: struct {
	logs:              [dynamic]string,
	feedback_failed:   [dynamic]string,
	feedback_ok:       int,
	suggestions:       [dynamic]string,
	suggestions_ok:    [dynamic]bool,
	reasons:           [dynamic]Reason,
	tracking_disabled: int,
	sessions_ready:    int,
}

fake_send :: proc(user: rawptr, t: ^Transfer, req: Http_Request) -> bool {
	f := (^Fake)(user)
	base := "https://api.ravensight.io/api/v1"
	path := strings.has_prefix(req.url, base) ? req.url[len(base):] : req.url
	r := Fake_Request{
		path    = strings.clone(path),
		body    = strings.clone(req.body),
		headers = make([dynamic]string),
		t       = t,
	}
	for h in req.headers {
		append(&r.headers, strings.clone(h))
	}
	append(&f.requests, r)
	return true
}

fake_now :: proc(user: rawptr) -> i64 {
	return (^Fake)(user).now
}

fake_idle :: proc(user: rawptr) {
	f := (^Fake)(user)
	f.now += 20
	if f.auto == nil {
		return
	}
	for i := 0; i < len(f.requests); i += 1 {
		if !f.requests[i].answered {
			status, body := f.auto(f.requests[i].path)
			answer(f, i, status, body)
		}
	}
}

// Answers request `idx` with `status` and a JSON `body`.
answer :: proc(f: ^Fake, idx: int, status: int, body := "", retry_after_ms: i64 = 0) {
	f.requests[idx].answered = true
	t := f.requests[idx].t
	append(&t.body_buf, ..transmute([]u8)body)
	finish_transfer(f.client, t, status, retry_after_ms)
}

// Index of the oldest unanswered request, or -1.
open_request :: proc(f: ^Fake) -> int {
	for r, i in f.requests {
		if !r.answered {
			return i
		}
	}
	return -1
}

// Answers the oldest unanswered request, expecting it to be `path`.
answer_next :: proc(t: ^testing.T, f: ^Fake, path: string, status: int, body := "", retry_after_ms: i64 = 0, loc := #caller_location) {
	idx := open_request(f)
	testing.expect(t, idx >= 0, "expected an open request", loc = loc)
	if idx < 0 {
		return
	}
	testing.expect_value(t, f.requests[idx].path, path, loc = loc)
	answer(f, idx, status, body, retry_after_ms)
}

has_header :: proc(r: Fake_Request, header: string) -> bool {
	for h in r.headers {
		if h == header {
			return true
		}
	}
	return false
}

record_log :: proc(user: rawptr, level: Log_Level, message: string) {
	r := (^Recorder)(user)
	append(&r.logs, fmt.aprintf("%v %s", level, message))
}

recorder_callbacks :: proc(r: ^Recorder) -> Callbacks {
	return Callbacks{
		user = r,
		on_log = record_log,
		on_feedback_failed = proc(user: rawptr, reason: string) {
			r := (^Recorder)(user)
			append(&r.feedback_failed, strings.clone(reason))
		},
		on_feedback_submitted = proc(user: rawptr) {
			(^Recorder)(user).feedback_ok += 1
		},
		on_suggestions = proc(user: rawptr, json: string, ok: bool) {
			r := (^Recorder)(user)
			append(&r.suggestions, strings.clone(json))
			append(&r.suggestions_ok, ok)
		},
		on_reason_changed = proc(user: rawptr, reason: Reason) {
			append(&(^Recorder)(user).reasons, reason)
		},
		on_tracking_disabled = proc(user: rawptr) {
			(^Recorder)(user).tracking_disabled += 1
		},
		on_session_ready = proc(user: rawptr) {
			(^Recorder)(user).sessions_ready += 1
		},
	}
}

recorder_destroy :: proc(r: ^Recorder) {
	for s in r.logs {delete(s)}
	for s in r.feedback_failed {delete(s)}
	for s in r.suggestions {delete(s)}
	delete(r.logs)
	delete(r.feedback_failed)
	delete(r.suggestions)
	delete(r.suggestions_ok)
	delete(r.reasons)
}

fake_init :: proc(f: ^Fake) {
	f.now = T0
	f.requests = make([dynamic]Fake_Request)
	tmp, _ := os.temp_directory(context.temp_allocator)
	f.dir = fmt.aprintf("%s/ravensight-test-%s", strings.trim_right(tmp, "/"), generate_device_id(context.temp_allocator))
}

fake_destroy :: proc(f: ^Fake) {
	for r in f.requests {
		delete(r.path)
		delete(r.body)
		for h in r.headers {delete(h)}
		delete(r.headers)
	}
	delete(f.requests)
	os.remove_all(f.dir)
	delete(f.dir)
}

storage_in :: proc(f: ^Fake) -> string {
	return fmt.tprintf("%s/ravensight.json", f.dir)
}

// Creates a client on the fake. Storage defaults to the fake's folder.
fake_client :: proc(t: ^testing.T, f: ^Fake, cfg: Config) -> ^Client {
	cfg := cfg
	if len(cfg.ingest_key) == 0 {
		cfg.ingest_key = "gt_live_test"
	}
	if len(cfg.storage_path) == 0 {
		cfg.storage_path = storage_in(f)
	}
	transport := Transport{user = f, send = fake_send, now = fake_now, idle = fake_idle}
	cl, err := create_with_transport(cfg, transport, false)
	testing.expect_value(t, err, Error.None)
	f.client = cl
	return cl
}

// Frees a client without the quit flush.
close_client :: proc(cl: ^Client) {
	shutdown(cl, 0)
}

count_requests :: proc(f: ^Fake, path: string) -> int {
	n := 0
	for r in f.requests {
		if r.path == path {
			n += 1
		}
	}
	return n
}

// Drives settings and session to a ready client.
boot_client :: proc(t: ^testing.T, f: ^Fake, cl: ^Client, loc := #caller_location) {
	tick(cl)
	answer_next(t, f, "/settings", 200, `{"trackingEnabled":true}`, loc = loc)
	tick(cl)
	answer_next(t, f, "/session", 201, `{"token":"tok_1","expiresIn":86400}`, loc = loc)
}

// --- Disabled and opt-out -------------------------------------------------------

@(test)
test_client_disabled_start_makes_zero_requests :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{start_disabled = true, callbacks = recorder_callbacks(&rec)})

	testing.expect(t, !is_active(cl))
	testing.expect_value(t, init_reason(cl), Reason.Disabled)
	testing.expect_value(t, queue_len(cl), 0) // game_started not queued while disabled
	testing.expect(t, !track(cl, "level_start"))
	flush(cl, force = true)
	testing.expect(t, !fetch_suggestions(cl))
	testing.expect(t, !submit_feedback(cl, "hello", "bug", 4))
	for _ in 0 ..< 50 {
		f.now += 1_000
		tick(cl)
	}
	testing.expect_value(t, len(f.requests), 0)
	testing.expect_value(t, len(rec.suggestions), 1)
	testing.expect_value(t, rec.suggestions[0], "[]")
	testing.expect(t, !rec.suggestions_ok[0])
	testing.expect_value(t, len(rec.feedback_failed), 1)
	testing.expect_value(t, rec.feedback_failed[0], "disabled")

	// Enabled later: game_started is queued then, once, and the boot begins.
	set_enabled(cl, true)
	testing.expect_value(t, queue_len(cl), 1)
	testing.expect_value(t, cl.core.queue[0].name, "game_started")
	set_enabled(cl, false)
	set_enabled(cl, true)
	testing.expect_value(t, queue_len(cl), 0) // once-guard: not queued again
	tick(cl)
	testing.expect_value(t, len(f.requests), 1)
	testing.expect_value(t, f.requests[0].path, "/settings")
	close_client(cl)
}

@(test)
test_client_saved_opt_out_survives_a_new_client :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)

	a := fake_client(t, &f, Config{})
	first_id := strings.clone(device_id(a), context.temp_allocator)
	set_tracking_enabled(a, false)
	testing.expect_value(t, queue_len(a), 0) // game_started discarded
	testing.expect(t, !is_tracking_enabled(a))
	shutdown(a) // the quit path sends nothing while opted out
	testing.expect_value(t, len(f.requests), 0)

	b := fake_client(t, &f, Config{}) // Config says nothing; the file wins
	testing.expect(t, !is_active(b))
	testing.expect(t, !is_tracking_enabled(b))
	testing.expect_value(t, init_reason(b), Reason.Disabled)
	testing.expect_value(t, device_id(b), first_id)
	testing.expect(t, !track(b, "e"))
	for _ in 0 ..< 20 {
		f.now += 5_000
		tick(b)
	}
	shutdown(b)
	testing.expect_value(t, len(f.requests), 0)
}

@(test)
test_client_opt_out_before_create :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	testing.expect(t, write_tracking_enabled(false, storage_in(&f)))

	cl := fake_client(t, &f, Config{})
	testing.expect(t, !is_active(cl))
	tick(cl)
	testing.expect_value(t, len(f.requests), 0)

	// Opting back in starts the run: game_started once, then settings.
	set_tracking_enabled(cl, true)
	testing.expect_value(t, queue_len(cl), 1)
	set_tracking_enabled(cl, true)
	testing.expect_value(t, queue_len(cl), 1)
	tick(cl)
	testing.expect_value(t, f.requests[0].path, "/settings")
	close_client(cl)

	saved := load_identity(storage_in(&f), context.temp_allocator)
	testing.expect(t, saved.tracking_enabled)
}

@(test)
test_client_set_tracking_enabled_writes_when_created_disabled :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{start_disabled = true})
	set_tracking_enabled(cl, false)
	close_client(cl)

	saved := load_identity(storage_in(&f), context.temp_allocator)
	testing.expect(t, !saved.tracking_enabled)
	testing.expect(t, strings.has_prefix(saved.device_id, "dev_"))
	testing.expect_value(t, len(f.requests), 0)
}

@(test)
test_client_opt_out_mid_run_clears_queue_and_stops :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	boot_client(t, &f, cl)
	track(cl, "a")
	track(cl, "b")
	set_tracking_enabled(cl, false)
	testing.expect_value(t, queue_len(cl), 0)
	before := len(f.requests)
	for _ in 0 ..< 20 {
		f.now += 5_000
		tick(cl)
	}
	testing.expect_value(t, len(f.requests), before)
	close_client(cl)
}

// --- Device id ---------------------------------------------------------------------

is_dev_id :: proc(id: string) -> bool {
	if len(id) != 36 || !strings.has_prefix(id, "dev_") {
		return false
	}
	for ch in id[4:] {
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) {
			return false
		}
	}
	return true
}

@(test)
test_client_device_id_is_saved_and_reused :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)

	a := fake_client(t, &f, Config{})
	id := strings.clone(device_id(a), context.temp_allocator)
	testing.expect(t, is_dev_id(id), id)
	close_client(a)

	b := fake_client(t, &f, Config{})
	testing.expect_value(t, device_id(b), id)
	close_client(b)

	// Config.device_id overrides for the run and never rewrites the file.
	c := fake_client(t, &f, Config{device_id = "my_own_id"})
	testing.expect_value(t, device_id(c), "my_own_id")
	boot_client(t, &f, c)
	testing.expect(t, strings.contains(f.requests[len(f.requests) - 1].body, `"deviceId":"my_own_id"`))
	close_client(c)
	testing.expect_value(t, load_identity(storage_in(&f), context.temp_allocator).device_id, id)

	// An existing saved id in another format is kept as it is.
	testing.expect(t, save_identity(storage_in(&f), Saved_Identity{"0123456789abcdef0123456789abcdef-macos", true}))
	d := fake_client(t, &f, Config{})
	testing.expect_value(t, device_id(d), "0123456789abcdef0123456789abcdef-macos")
	close_client(d)
}

@(test)
test_client_reset_device_id :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	old := strings.clone(device_id(cl), context.temp_allocator)
	boot_client(t, &f, cl)
	testing.expect_value(t, session_token(cl), "tok_1")
	track(cl, "a")

	fresh := reset_device_id(cl)
	testing.expect(t, is_dev_id(fresh))
	testing.expect(t, fresh != old)
	testing.expect_value(t, device_id(cl), fresh)
	testing.expect_value(t, queue_len(cl), 0)
	testing.expect_value(t, session_token(cl), "")
	testing.expect_value(t, load_identity(storage_in(&f), context.temp_allocator).device_id, fresh)

	// The next session is opened under the new id.
	track(cl, "after_reset")
	tick(cl)
	last := f.requests[len(f.requests) - 1]
	testing.expect_value(t, last.path, "/session")
	testing.expect(t, strings.contains(last.body, fresh))
	close_client(cl)
}

// --- Lifecycle -----------------------------------------------------------------------

@(test)
test_client_game_started_first_with_create_time_and_once :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	testing.expect_value(t, queue_len(cl), 1)
	testing.expect_value(t, cl.core.queue[0].name, "game_started")
	testing.expect_value(t, cl.core.queue[0].timestamp_s, T0 / 1000)

	// Tracked before the first tick, still behind game_started.
	f.now += 3_000
	track(cl, "level_start")
	boot_client(t, &f, cl)
	set_enabled(cl, true)
	set_tracking_enabled(cl, true)
	flush(cl)
	tick(cl)
	last := f.requests[len(f.requests) - 1]
	testing.expect_value(t, last.path, "/track/batch")
	testing.expect_value(t, strings.count(last.body, `"game_started"`), 1)
	testing.expect(t, strings.index(last.body, "game_started") < strings.index(last.body, "level_start"))
	testing.expect(t, strings.contains(last.body, fmt.tprintf(`"timestamp":%d`, T0 / 1000)))
	close_client(cl)
}

@(test)
test_client_game_exited_once_on_shutdown :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	boot_client(t, &f, cl)
	f.auto = proc(path: string) -> (int, string) {
		return 202, `{"accepted":1}`
	}
	start := f.now
	shutdown(cl)
	exited := 0
	for r in f.requests {
		exited += strings.count(r.body, `"game_exited"`)
	}
	testing.expect_value(t, exited, 1)
	testing.expect(t, f.now - start <= QUIT_FLUSH_TIMEOUT_MS)
}

@(test)
test_client_shutdown_holds_at_most_the_quit_timeout :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	start := f.now
	shutdown(cl) // nothing ever answers
	testing.expect(t, f.now - start <= QUIT_FLUSH_TIMEOUT_MS + 20)
	testing.expect_value(t, len(f.requests), 1) // the settings check, unanswered
}

@(test)
test_client_lifecycle_can_be_turned_off :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{disable_lifecycle_events = true})
	testing.expect_value(t, queue_len(cl), 0)
	shutdown(cl)
	testing.expect_value(t, len(f.requests), 0)
}

// --- Failures ------------------------------------------------------------------------

@(test)
test_client_settings_401_one_request_then_none :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{callbacks = recorder_callbacks(&rec)})
	tick(cl)
	answer_next(t, &f, "/settings", 401, `{"error":"invalid_api_key"}`)
	for _ in 0 ..< 100 {
		f.now += 10_000
		track(cl, "e")
		tick(cl)
	}
	testing.expect_value(t, len(f.requests), 1)
	testing.expect_value(t, init_reason(cl), Reason.Invalid_Key)
	testing.expect_value(t, len(rec.reasons), 1)
	testing.expect_value(t, rec.reasons[0], Reason.Invalid_Key)
	testing.expect(t, queue_len(cl) > 0) // queue kept

	warnings := 0
	for l in rec.logs {
		if l == fmt.tprintf("Warning %s", INVALID_KEY_WARNING) {
			warnings += 1
		}
		testing.expect(t, !strings.contains(l, "assuming tracking enabled"), l)
	}
	testing.expect_value(t, warnings, 1)

	// flush() makes exactly one more attempt.
	flush(cl)
	tick(cl)
	testing.expect_value(t, len(f.requests), 2)
	answer_next(t, &f, "/session", 401, `{"error":"invalid_api_key"}`)
	tick(cl)
	f.now += 1_000_000
	tick(cl)
	testing.expect_value(t, len(f.requests), 2)
	shutdown(cl) // no quit flush against a refused key
	testing.expect_value(t, len(f.requests), 2)
}

@(test)
test_client_session_403_tracking_disabled_stops :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{callbacks = recorder_callbacks(&rec)})
	testing.expect(t, submit_feedback(cl, "waiting for a session", "suggestion"))
	tick(cl)
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":true}`)
	tick(cl)
	answer_next(t, &f, "/session", 403, `{"error":"tracking_disabled"}`)
	testing.expect_value(t, init_reason(cl), Reason.Tracking_Disabled)
	testing.expect_value(t, rec.tracking_disabled, 1)
	testing.expect_value(t, queue_len(cl), 0)
	testing.expect_value(t, len(rec.feedback_failed), 1) // the waiting feedback
	testing.expect(t, !fetch_suggestions(cl))
	for _ in 0 ..< 50 {
		f.now += 10_000
		track(cl, "e")
		tick(cl)
	}
	shutdown(cl)
	testing.expect_value(t, len(f.requests), 2)
}

@(test)
test_client_kill_switch_gates_suggestions :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{callbacks = recorder_callbacks(&rec)})
	tick(cl)
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":false}`)
	testing.expect(t, !fetch_suggestions(cl))
	testing.expect_value(t, len(f.requests), 1)
	testing.expect_value(t, rec.suggestions[0], "[]")
	testing.expect(t, !rec.suggestions_ok[0])
	close_client(cl)
}

@(test)
test_client_suggestions_when_active :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{callbacks = recorder_callbacks(&rec)})
	testing.expect(t, fetch_suggestions(cl))
	r := f.requests[0]
	testing.expect_value(t, r.path, "/agent/suggestions")
	testing.expect(t, has_header(r, "X-API-Key: gt_live_test"))
	answer(&f, 0, 200, `{"suggestions":[{"title":"x"}]}`)
	testing.expect_value(t, rec.suggestions[0], `[{"title":"x"}]`)
	testing.expect(t, rec.suggestions_ok[0])
	close_client(cl)
}

// --- Feedback ------------------------------------------------------------------------

@(test)
test_client_feedback_validation :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{callbacks = recorder_callbacks(&rec)})
	boot_client(t, &f, cl)
	before := len(f.requests)

	testing.expect(t, !submit_feedback(cl, "x", "rant"))
	testing.expect(t, !submit_feedback(cl, "x", "bug", 6))
	testing.expect(t, !submit_feedback(cl, "x", "bug", -1))
	testing.expect(t, !submit_feedback(cl, "   ", "bug"))
	testing.expect_value(t, len(f.requests), before)
	testing.expect_value(t, len(rec.feedback_failed), 4)
	testing.expect_value(t, rec.feedback_failed[0], "invalid_category")
	testing.expect_value(t, rec.feedback_failed[1], "invalid_rating")
	testing.expect_value(t, rec.feedback_failed[2], "invalid_rating")
	testing.expect_value(t, rec.feedback_failed[3], "empty_message")

	testing.expect(t, submit_feedback(cl, "Jump feels floaty", category = "bug", rating = 4))
	r := f.requests[len(f.requests) - 1]
	testing.expect_value(t, r.path, "/feedback")
	testing.expect_value(t, r.body, `{"message":"Jump feels floaty","category":"bug","rating":4}`)
	testing.expect(t, has_header(r, "X-Session-Token: tok_1"))
	answer(&f, len(f.requests) - 1, 201, `{"ok":true}`)
	testing.expect_value(t, rec.feedback_ok, 1)

	// Rating 0 and no category are omitted.
	testing.expect(t, submit_feedback(cl, "plain"))
	testing.expect_value(t, f.requests[len(f.requests) - 1].body, `{"message":"plain"}`)
	for cat in FEEDBACK_CATEGORIES {
		testing.expect(t, is_feedback_category(cat))
	}
	close_client(cl)
}

@(test)
test_client_feedback_before_session_waits_for_it :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{disable_lifecycle_events = true, callbacks = recorder_callbacks(&rec)})
	for i in 0 ..< MAX_PENDING_FEEDBACK {
		testing.expect(t, submit_feedback(cl, fmt.tprintf("early %d", i), "other"))
	}
	testing.expect(t, !submit_feedback(cl, "one too many", "other"))
	testing.expect_value(t, rec.feedback_failed[0], "queue_full")
	testing.expect_value(t, len(f.requests), 0)

	// The empty event queue still opens a session for the waiting feedback.
	boot_client(t, &f, cl)
	testing.expect_value(t, count_requests(&f, "/feedback"), MAX_PENDING_FEEDBACK)
	for i := open_request(&f); i >= 0; i = open_request(&f) {
		answer(&f, i, 201, `{}`)
	}
	testing.expect_value(t, rec.feedback_ok, MAX_PENDING_FEEDBACK)
	close_client(cl)
}

// --- Playtest ------------------------------------------------------------------------

@(test)
test_client_playtest_identity_header_and_no_storage :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	// A saved opt-out on disk is ignored by a playtest run.
	testing.expect(t, write_tracking_enabled(false, storage_in(&f)))
	before, _ := os.read_entire_file(storage_in(&f), context.temp_allocator)

	cl := fake_client(t, &f, Config{
		playtest_token = "pt_tok",
		playtest_run_id = "run42",
		playtest_job_id = "job7",
		playtest_persona = "speedrunner",
		callbacks = recorder_callbacks(&rec),
	})
	testing.expect(t, is_playtest(cl))
	testing.expect(t, is_active(cl))
	testing.expect_value(t, device_id(cl), "pt-run42")

	set_tracking_enabled(cl, false) // no-op, one log line
	testing.expect(t, is_active(cl))
	testing.expect_value(t, reset_device_id(cl), "pt-run42")
	testing.expect_value(t, len(rec.logs), 2)

	boot_client(t, &f, cl)
	Level :: struct {
		level: int,
	}
	track(cl, "level_start", Level{level = 1})
	flush(cl)
	tick(cl)
	for r in f.requests {
		testing.expect(t, has_header(r, "X-Ravensight-Playtest: pt_tok"), r.path)
	}
	testing.expect(t, strings.contains(f.requests[1].body, `"deviceId":"pt-run42"`))
	batch := f.requests[2].body
	testing.expect_value(t, f.requests[2].path, "/track/batch")
	testing.expect(t, strings.contains(batch, `{"level":1,"synthetic":true,"pt_source":"sdk","pt_run":"run42","pt_job":"job7","persona":"speedrunner"}`), batch)

	// The run's job closes: permanent stop, queue cleared, logged once.
	answer(&f, 2, 403, `{"error":"playtest_job_closed"}`)
	testing.expect_value(t, init_reason(cl), Reason.Playtest_Job_Closed)
	testing.expect_value(t, queue_len(cl), 0)
	n := len(f.requests)
	for _ in 0 ..< 20 {
		f.now += 10_000
		track(cl, "e")
		flush(cl, force = true)
		tick(cl)
	}
	shutdown(cl)
	testing.expect_value(t, len(f.requests), n)

	// Nothing was written: the file is byte for byte what it was.
	after, _ := os.read_entire_file(storage_in(&f), context.temp_allocator)
	testing.expect_value(t, string(after), string(before))
}

@(test)
test_client_playtest_token_without_run_id_never_runs :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	rec: Recorder
	defer recorder_destroy(&rec)
	cl := fake_client(t, &f, Config{playtest_token = "pt_tok", callbacks = recorder_callbacks(&rec)})
	testing.expect(t, is_playtest(cl))
	testing.expect_value(t, init_reason(cl), Reason.Session_Failed)
	testing.expect(t, !track(cl, "e"))
	tick(cl)
	shutdown(cl)
	testing.expect_value(t, len(f.requests), 0)
	testing.expect_value(t, len(rec.logs), 1)
	testing.expect(t, !os.exists(storage_in(&f)))
}

@(test)
test_resolve_playtest_sources :: proc(t: ^testing.T) {
	args := []string{"game", "--ravensight-playtest-token=arg_tok", "--ravensight-playtest-run-id=arg_run"}
	env := Playtest_Context{token = "env_tok", run_id = "env_run", job_id = "env_job", persona = "env_p"}

	got := resolve_playtest(Playtest_Context{token = "cfg_tok"}, env, args)
	testing.expect_value(t, got.token, "cfg_tok")
	testing.expect_value(t, got.run_id, "env_run")
	testing.expect_value(t, got.job_id, "env_job")

	got = resolve_playtest({}, {}, args)
	testing.expect_value(t, got.token, "arg_tok")
	testing.expect_value(t, got.run_id, "arg_run")

	got = resolve_playtest({}, {}, []string{"game"})
	testing.expect_value(t, got.token, "")
}

// --- Misc ----------------------------------------------------------------------------

@(test)
test_client_session_token_accessor :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	testing.expect_value(t, session_token(cl), "")
	boot_client(t, &f, cl)
	testing.expect_value(t, session_token(cl), "tok_1")
	close_client(cl)
}

@(test)
test_client_batch_body_and_auth_headers :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{api_url = "https://api.ravensight.io/api/v1/"})
	tick(cl)
	testing.expect(t, has_header(f.requests[0], "X-API-Key: gt_live_test"))
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":true}`)
	tick(cl)
	testing.expect(t, has_header(f.requests[1], "X-API-Key: gt_live_test"))
	testing.expect(t, !has_header(f.requests[1], "X-Ravensight-Playtest: "))
	answer_next(t, &f, "/session", 201, `{"token":"tok_1"}`)
	for i in 0 ..< MAX_BATCH_SIZE {
		track(cl, fmt.tprintf("e%d", i))
	}
	tick(cl) // 51 queued: one full batch goes at once, no timer wait
	r := f.requests[2]
	testing.expect_value(t, r.path, "/track/batch")
	testing.expect(t, has_header(r, "X-Session-Token: tok_1"))
	testing.expect_value(t, strings.count(r.body, `"event":`), MAX_BATCH_SIZE)
	close_client(cl)
}

@(test)
test_nil_client_is_a_no_op :: proc(t: ^testing.T) {
	cl: ^Client
	tick(cl)
	testing.expect(t, !track(cl, "e"))
	flush(cl)
	testing.expect(t, !submit_feedback(cl, "x"))
	testing.expect(t, !fetch_suggestions(cl))
	set_enabled(cl, false)
	set_tracking_enabled(cl, false)
	testing.expect_value(t, reset_device_id(cl), "")
	testing.expect_value(t, session_token(cl), "")
	testing.expect(t, !is_active(cl))
	testing.expect(t, !is_ready(cl))
	testing.expect_value(t, queue_len(cl), 0)
	shutdown(cl)
}
