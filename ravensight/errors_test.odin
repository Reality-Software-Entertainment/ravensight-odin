// errors_test.odin - automatic error capture through the fake transport.
//
// The hooks feed one bound client through package state, so every test
// here that binds a client holds capture_test_mutex for its whole run. The
// game's previous logger is a recording sink, never the test runner's own
// logger (which would fail a test on any .Error line). A failed expectation
// is reported through context.logger too, so the sink hands those lines
// ("expected ...", "FAIL") back to the runner's logger; without that, every
// expectation made after the capture logger is installed passes silently.

package ravensight

import "base:runtime"
import "core:encoding/json"
import clog "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

capture_test_mutex: sync.Mutex

Log_Sink :: struct {
	lines:  [dynamic]string,
	runner: runtime.Logger, // the test runner's logger, for failed expectations
}

sink_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	sink := (^Log_Sink)(data)
	if level >= .Error && (strings.has_prefix(text, "expected ") || strings.has_prefix(text, "FAIL")) && sink.runner.procedure != nil {
		sink.runner.procedure(sink.runner.data, level, text, sink.runner.options, location)
		return
	}
	append(&sink.lines, strings.clone(text, runtime.heap_allocator()), )
}

sink_logger :: proc(sink: ^Log_Sink, lowest := runtime.Logger_Level.Debug) -> runtime.Logger {
	if sink.runner.procedure == nil {
		sink.runner = context.logger
	}
	return runtime.Logger{procedure = sink_proc, data = sink, lowest_level = lowest}
}

sink_destroy :: proc(sink: ^Log_Sink) {
	for l in sink.lines {
		delete(l, runtime.heap_allocator())
	}
	delete(sink.lines)
}

// A client on the fake, bound to the hooks. Pair with capture_close.
capture_client :: proc(t: ^testing.T, f: ^Fake, cfg: Config = {}) -> ^Client {
	cl := fake_client(t, f, cfg)
	capture_bind(cl)
	return cl
}

capture_close :: proc(cl: ^Client) {
	close_client(cl)
}

SESSION_OK :: `{"token":"tok_1","expiresIn":86400}`

// Settings then session, with `settings_body` carrying any errorCapture.
capture_boot :: proc(t: ^testing.T, f: ^Fake, cl: ^Client, settings_body := `{"trackingEnabled":true}`, loc := #caller_location) {
	tick(cl)
	answer_next(t, f, "/settings", 200, settings_body, loc = loc)
	tick(cl)
	answer_next(t, f, "/session", 201, SESSION_OK, loc = loc)
	idx := open_request(f)
	if idx >= 0 && strings.has_prefix(f.requests[idx].path, "/ingest/config?") {
		answer(f, idx, 0)
	}
}

// The queued error events' data, oldest first.
queued_errors :: proc(cl: ^Client) -> []json.Object {
	out := make([dynamic]json.Object, context.temp_allocator)
	for evt in cl.core.queue {
		if evt.name != "error" {
			continue
		}
		val, err := json.parse(transmute([]u8)evt.data_json, allocator = context.temp_allocator)
		if err != nil {
			continue
		}
		if o, ok := val.(json.Object); ok {
			append(&out, o)
		}
	}
	return out[:]
}

str_of :: proc(o: json.Object, key: string) -> string {
	s, _ := o[key].(json.String)
	return string(s)
}

@(test)
test_capture_logger_forwards_and_captures_errors :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f)
	capture_boot(t, &f, cl)

	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	clog.info("loading level 2")
	clog.warn("texture missing")
	clog.error("save failed for slot 3 at /Users/jacob/saves/slot3.dat")
	clog.fatal("renderer lost")

	// The game's own logger sees every line, unchanged.
	testing.expect_value(t, len(sink.lines), 4)
	testing.expect_value(t, sink.lines[2], "save failed for slot 3 at /Users/jacob/saves/slot3.dat")

	testing.expect_value(t, len(queued_errors(cl)), 0) // captured on the next tick
	tick(cl)
	errs := queued_errors(cl)
	testing.expect_value(t, len(errs), 2)
	if len(errs) == 2 {
		e := errs[0]
		testing.expect_value(t, str_of(e, "rs_kind"), "error")
		testing.expect_value(t, str_of(e, "rs_severity"), "warning")
		testing.expect_value(t, str_of(e, "rs_source"), "log")
		testing.expect_value(t, str_of(e, "rs_error_type"), "log.Error")
		testing.expect_value(t, str_of(e, "rs_message"), "save failed for slot 3 at ~/saves/slot3.dat")
		stack := str_of(e, "rs_stack")
		testing.expect(t, strings.has_prefix(stack, "at test_capture_logger_forwards_and_captures_errors ("))
		testing.expect(t, strings.contains(stack, "errors_test.odin:"))
		_, has_trail := e["rs_trail"]
		testing.expect(t, !has_trail) // the trail switch is off by default
		testing.expect_value(t, str_of(errs[1], "rs_severity"), "critical")
		testing.expect_value(t, str_of(errs[1], "rs_error_type"), "log.Fatal")
	}
	capture_close(cl)
}

@(test)
test_capture_trail_only_with_the_switch_and_only_on_an_error :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f)
	capture_boot(t, &f, cl, `{"trackingEnabled":true,"errorCapture":{"enabled":true,"trail":true}}`)

	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	f.now += 1_500
	clog.info("entered cave")
	f.now += 250
	clog.warn("player email jane@example.com is unverified")
	tick(cl)
	testing.expect_value(t, len(queued_errors(cl)), 0) // never sent alone

	clog.error("boss spawn failed")
	clog.info("after the error")
	tick(cl)
	errs := queued_errors(cl)
	testing.expect_value(t, len(errs), 1)
	if len(errs) == 1 {
		testing.expect_value(t, str_of(errs[0], "rs_trail"), "+1500 info entered cave\n+1750 warning player email [email] is unverified")
	}
	capture_close(cl)
}

@(test)
test_capture_switched_off_by_the_game_sends_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f)
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)

	clog.error("boot error before the answer")
	tick(cl) // held
	testing.expect_value(t, len(cl.capture.held), 1)
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":true,"errorCapture":{"enabled":false,"trail":true}}`)
	testing.expect_value(t, len(cl.capture.held), 0) // discarded unsent
	clog.error("later error")
	tick(cl)
	testing.expect_value(t, len(queued_errors(cl)), 0)
	testing.expect_value(t, len(sink.lines), 2) // still forwarded

	// Manual track_error is never blocked by the switch, and is not scrubbed
	// on the device (the server scrubs it).
	testing.expect(t, track_error(cl, SEVERITY_ERROR, "save at /Users/jacob/x failed"))
	errs := queued_errors(cl)
	testing.expect_value(t, len(errs), 1)
	if len(errs) == 1 {
		testing.expect_value(t, str_of(errs[0], "rs_message"), "save at /Users/jacob/x failed")
		_, has_source := errs[0]["rs_source"]
		testing.expect(t, !has_source)
	}
	capture_close(cl)
}

@(test)
test_capture_boot_hold_keeps_five_until_the_answer :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f)
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)

	words := [?]string{"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"}
	for w in words {
		clog.errorf("boot failure %s", w)
	}
	tick(cl) // starts /settings; nothing known yet
	testing.expect_value(t, len(cl.capture.held), 5)
	testing.expect_value(t, len(queued_errors(cl)), 0)

	// An answer with no errorCapture at all means on.
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":true}`)
	testing.expect_value(t, len(cl.capture.held), 0)
	errs := queued_errors(cl)
	testing.expect_value(t, len(errs), 5)
	if len(errs) == 5 {
		testing.expect_value(t, str_of(errs[0], "rs_message"), "boot failure alpha")
		testing.expect_value(t, str_of(errs[4], "rs_message"), "boot failure echo")
	}
	// Gameplay stays ahead of the released errors.
	testing.expect_value(t, cl.core.queue[0].name, "game_started")
	capture_close(cl)
}

@(test)
test_capture_nothing_without_a_key_or_consent :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	sink: Log_Sink
	defer sink_destroy(&sink)

	{
		f: Fake
		fake_init(&f)
		defer fake_destroy(&f)
		cl := inert_client(t, &f, Config{optional = true})
		capture_bind(cl)
		context.logger = logger(sink_logger(&sink))
		defer destroy_logger(context.logger)
		testing.expect(t, !capture_global.armed)
		clog.error("no key error")
		tick(cl)
		testing.expect_value(t, len(f.requests), 0)
		testing.expect_value(t, queue_len(cl), 0)
		testing.expect_value(t, capture_global.inbox_len, 0)
		capture_close(cl)
	}
	{
		f: Fake
		fake_init(&f)
		defer fake_destroy(&f)
		cl := capture_client(t, &f, Config{consent = .Opt_In})
		context.logger = logger(sink_logger(&sink))
		defer destroy_logger(context.logger)
		clog.error("before the yes")
		tick(cl)
		testing.expect_value(t, len(f.requests), 0)
		testing.expect_value(t, len(cl.capture.held), 0)
		testing.expect_value(t, capture_global.inbox_len, 0)

		// After the yes, capture runs; an opt-out stops it again.
		set_tracking_enabled(cl, true)
		testing.expect(t, capture_global.armed)
		clog.error("after the yes")
		tick(cl)
		testing.expect_value(t, len(cl.capture.held), 1)
		set_tracking_enabled(cl, false)
		testing.expect(t, !capture_global.armed)
		testing.expect_value(t, len(cl.capture.held), 0)
		capture_close(cl)
	}
	testing.expect_value(t, len(sink.lines), 3)
}

Sdk_Loop :: struct {
	logged: int,
}

@(test)
test_capture_never_takes_the_sdks_own_lines :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	// A host that sends the SDK's lines and failures to its own logger.
	cb := Callbacks{
		on_log = proc(user: rawptr, level: Log_Level, message: string) {
			clog.error(message)
		},
		on_flush_failed = proc(user: rawptr, reason: string) {
			clog.errorf("analytics flush failed: %s", reason)
		},
		on_session_ready = proc(user: rawptr) {
			clog.error("session callback error")
		},
	}
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	cl := capture_client(t, &f, Config{callbacks = cb})
	capture_boot(t, &f, cl)
	tick(cl)
	big := strings.repeat("x", MAX_EVENT_BYTES + 10, context.temp_allocator)
	testing.expect(t, !track(cl, "too_big", Blob{blob = big})) // on_log and on_flush_failed fire here
	clog.error("Ravensight: a line that looks like the SDK's")
	tick(cl)
	testing.expect_value(t, len(queued_errors(cl)), 0)
	testing.expect(t, len(sink.lines) >= 3) // all forwarded
	capture_close(cl)
}

@(test)
test_capture_caps_per_run_key_and_minute :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f, Config{max_queue_size = 1000, flush_interval_ms = -1})
	capture_boot(t, &f, cl, `{"trackingEnabled":true,"errorCapture":{"enabled":true,"trail":true}}`)
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)

	// The bucket: 6 at once, then one every 10 seconds.
	words := [?]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"}
	for w in words {
		clog.warn("before") // feeds the trail
		clog.errorf("burst %s", w)
	}
	tick(cl)
	testing.expect_value(t, len(queued_errors(cl)), 6)
	f.now += 10_000
	clog.error("burst k")
	clog.error("burst l")
	tick(cl)
	testing.expect_value(t, len(queued_errors(cl)), 7)

	// The same key at most 3 times (digits read as one placeholder).
	for i in 0 ..< 6 {
		f.now += 60_000
		clog.errorf("enemy %d not found", i)
		tick(cl)
	}
	testing.expect_value(t, len(queued_errors(cl)), 10)

	// 30 a run, whatever the time; trails on 10 of them at most.
	letters := "mnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	for i in 0 ..< len(letters) {
		f.now += 60_000
		clog.warn("before")
		clog.errorf("late %c", letters[i])
		tick(cl)
	}
	errs := queued_errors(cl)
	testing.expect_value(t, len(errs), MAX_CAPTURES_PER_RUN)
	with_trail := 0
	for e in errs {
		if _, has := e["rs_trail"]; has {
			with_trail += 1
		}
	}
	testing.expect_value(t, with_trail, MAX_TRAILS_PER_RUN)
	capture_close(cl)
}

Thread_Log :: struct {
	logger: runtime.Logger,
}

@(test)
test_capture_from_another_thread_lands_on_the_next_tick :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f)
	capture_boot(t, &f, cl)

	data := Thread_Log{logger = logger(sink_logger(&sink))}
	defer destroy_logger(data.logger)
	th := thread.create_and_start_with_poly_data(&data, proc(d: ^Thread_Log) {
		context.logger = d.logger
		clog.error("worker thread failed")
	})
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, capture_global.inbox_len, 1)
	tick(cl)
	errs := queued_errors(cl)
	testing.expect_value(t, len(errs), 1)
	if len(errs) == 1 {
		testing.expect_value(t, str_of(errs[0], "rs_message"), "worker thread failed")
	}
	capture_close(cl)
}

@(test)
test_capture_crash_persists_and_sends_on_next_launch :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	base := strings.concatenate({storage_in(&f), CRASH_FILE_SUFFIX}, context.temp_allocator)
	crash_path := crash_file_path(base, 0)

	a := capture_client(t, &f)
	capture_boot(t, &f, a, `{"trackingEnabled":true,"errorCapture":{"enabled":true,"trail":true}}`)
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	f.now = T0
	clog.info("opened inventory")
	// What the assertion procedure does before it calls the previous one.
	loc := runtime.Source_Code_Location{file_path = "/Users/jacob/game/src/inventory.odin", line = 88, column = 3, procedure = "move_item"}
	testing.expect(t, capture_persist_crash("runtime assertion", "slot 12 out of range for gt_live_abc123", loc))
	testing.expect(t, os.exists(crash_path))
	capture_close(a)

	b := capture_client(t, &f)
	testing.expect_value(t, len(b.capture.held), 1)
	testing.expect(t, os.exists(crash_path)) // kept until the server takes it
	// A second crash before the answer neither loses nor replaces the first.
	testing.expect(t, capture_persist_crash("panic", "second", loc))
	testing.expect(t, os.exists(crash_path))
	testing.expect(t, os.exists(crash_file_path(base, 1)))
	os.remove(crash_file_path(base, 1))
	capture_boot(t, &f, b, `{"trackingEnabled":true,"errorCapture":{"enabled":true,"trail":true}}`)
	errs := queued_errors(b)
	testing.expect_value(t, len(errs), 1)
	if len(errs) == 1 {
		e := errs[0]
		testing.expect_value(t, str_of(e, "rs_source"), "crash")
		testing.expect_value(t, str_of(e, "rs_severity"), "critical")
		testing.expect_value(t, str_of(e, "rs_error_type"), "runtime assertion")
		testing.expect_value(t, str_of(e, "rs_message"), "slot 12 out of range for [token]")
		testing.expect_value(t, str_of(e, "rs_stack"), "at move_item (~/game/src/inventory.odin:88:3)")
		testing.expect_value(t, str_of(e, "rs_trail"), "+0 info opened inventory")
	}
	testing.expect(t, os.exists(crash_path))
	flush(b, force = true)
	tick(b)
	answer_next(t, &f, "/track/batch", 202, `{"accepted":2}`)
	testing.expect(t, !os.exists(crash_path)) // accepted, so removed
	capture_close(b)
}

@(test)
test_capture_crash_dropped_unsent_after_opt_out :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	crash_path := crash_file_path(strings.concatenate({storage_in(&f), CRASH_FILE_SUFFIX}, context.temp_allocator), 0)

	a := capture_client(t, &f)
	loc := runtime.Source_Code_Location{file_path = "main.odin", line = 1, column = 1, procedure = "main"}
	testing.expect(t, capture_persist_crash("panic", "boom", loc))
	set_tracking_enabled(a, false)
	// Opted out: the assertion path writes nothing.
	testing.expect(t, !capture_persist_crash("panic", "boom again", loc))
	capture_close(a)

	b := capture_client(t, &f)
	testing.expect(t, !os.exists(crash_path))
	testing.expect_value(t, len(b.capture.held), 0)
	capture_close(b)

	// And reset_device_id forgets a crash of the old identity.
	testing.expect(t, write_tracking_enabled(true, storage_in(&f)))
	c := capture_client(t, &f)
	testing.expect(t, capture_persist_crash("panic", "boom", loc))
	reset_device_id(c)
	testing.expect(t, !os.exists(crash_path))
	capture_close(c)
}

@(test)
test_install_error_capture_chains_and_installs_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	sink: Log_Sink
	defer sink_destroy(&sink)
	context.logger = sink_logger(&sink, .Warning)
	saved_assert := capture_global.prev_assert
	defer capture_global.prev_assert = saved_assert
	previous_assert := context.assertion_failure_proc

	{
		context = install_error_capture()
		testing.expect(t, context.logger.procedure == capture_logger_proc)
		testing.expect(t, context.assertion_failure_proc == capture_assertion_failure_proc)
		testing.expect(t, capture_global.prev_assert == previous_assert)
		testing.expect_value(t, context.logger.lowest_level, runtime.Logger_Level.Info)
		first := context.logger
		context = install_error_capture() // a second install wraps nothing
		testing.expect(t, context.logger.data == first.data)
		testing.expect(t, capture_global.prev_assert == previous_assert)

		// Below the previous logger's own level nothing is forwarded.
		clog.info("info line")
		clog.warn("warn line")
		testing.expect_value(t, len(sink.lines), 1)
		restored := destroy_logger(context.logger)
		testing.expect(t, restored.procedure == sink_proc)
	}
}

@(test)
test_trail_lines_are_scrubbed_cut_and_bounded :: proc(t: ^testing.T) {
	long := strings.repeat("y", 300, context.temp_allocator)
	line := trail_line(42, .Warning, long)
	testing.expect_value(t, strings.rune_count(line), MAX_TRAIL_LINE_CHARS)
	testing.expect(t, strings.has_prefix(line, "+42 warning yyy"))
	testing.expect_value(t, trail_line(-5, .Info, "two\nlines"), "+0 info two lines")

	lines := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 25 {
		append(&lines, trail_line(i64(i), .Info, long))
	}
	joined := join_trail(lines[:])
	testing.expect(t, strings.rune_count(joined) <= MAX_TRAIL_CHARS)
	testing.expect(t, strings.has_suffix(joined, trail_line(24, .Info, long)))

	p := prepare_capture(SEVERITY_WARNING, ERROR_SOURCE_LOG, strings.repeat("T", 150, context.temp_allocator), strings.repeat("m", 300, context.temp_allocator), "a.odin", "f", 1, 2)
	testing.expect_value(t, strings.rune_count(p.message), MAX_ERROR_MESSAGE_CHARS)
	testing.expect_value(t, strings.rune_count(p.error_type), MAX_ERROR_TYPE_CHARS)
	testing.expect_value(t, p.stack, "at f (a.odin:1:2)")
	q := prepare_capture(SEVERITY_WARNING, ERROR_SOURCE_LOG, "log.Error", "enemy 7 lost", "a.odin", "f", 9, 9)
	r := prepare_capture(SEVERITY_WARNING, ERROR_SOURCE_LOG, "log.Error", "enemy 1234 lost", "a.odin", "f", 30, 1)
	testing.expect_value(t, q.key, r.key) // line and number do not split the key
}

@(test)
test_capture_crash_record_has_no_trail_unless_the_switch_is_on :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	crash_path := crash_file_path(strings.concatenate({storage_in(&f), CRASH_FILE_SUFFIX}, context.temp_allocator), 0)
	loc := runtime.Source_Code_Location{file_path = "main.odin", line = 1, column = 1, procedure = "main"}

	cl := capture_client(t, &f)
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	clog.info("player typed their name")
	// Before any answer the switch is unknown: no trail on disk.
	testing.expect(t, capture_persist_crash("panic", "boom", loc))
	p, ok := read_crash_file(crash_path, f.now)
	testing.expect(t, ok)
	testing.expect_value(t, p.trail, "")
	os.remove(crash_path)

	// Known and off: still none.
	capture_boot(t, &f, cl, `{"trackingEnabled":true,"errorCapture":{"enabled":true,"trail":false}}`)
	clog.info("another line")
	testing.expect(t, capture_persist_crash("panic", "boom", loc))
	p, ok = read_crash_file(crash_path, f.now)
	testing.expect(t, ok)
	testing.expect_value(t, p.trail, "")
	capture_close(cl)
}

@(test)
test_capture_spent_caps_scrub_nothing :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f, Config{max_queue_size = 1000, flush_interval_ms = -1})
	capture_boot(t, &f, cl, `{"trackingEnabled":true,"errorCapture":{"enabled":true,"trail":true}}`)
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	words := [?]string{"a", "b", "c", "d", "e", "f"}
	for w in words {
		clog.errorf("burst %s", w)
	}
	tick(cl)
	testing.expect_value(t, len(queued_errors(cl)), 6)
	// The bucket is empty: further errors (with a trail to format) are never scrubbed.
	before := scrub_calls
	for _ in 0 ..< 10 {
		clog.warn("before")
		clog.error("late gt_live_abc123")
	}
	tick(cl)
	testing.expect_value(t, scrub_calls, before)
	testing.expect_value(t, len(queued_errors(cl)), 6)
	capture_close(cl)
}

@(test)
test_capture_trail_off_lines_are_not_copied :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f)
	capture_boot(t, &f, cl, `{"trackingEnabled":true,"errorCapture":{"enabled":true,"trail":false}}`)
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	clog.info("not kept")
	clog.warn("not kept either")
	testing.expect_value(t, capture_global.trail_seq, 0)
	capture_close(cl)
}

@(test)
test_capture_warnings_never_push_out_a_critical :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	sink: Log_Sink
	defer sink_destroy(&sink)
	cl := capture_client(t, &f, Config{max_queue_size = 1000, flush_interval_ms = -1})
	context.logger = logger(sink_logger(&sink))
	defer destroy_logger(context.logger)
	// Before the answer: many trail lines and warnings, then one critical line.
	for i in 0 ..< 200 {
		clog.infof("frame %d", i)
		clog.errorf("noise %d", i)
	}
	testing.expect_value(t, capture_global.inbox_len, CAPTURE_INBOX_SIZE)
	clog.fatal("the real one")
	tick(cl)
	testing.expect_value(t, len(cl.capture.held), MAX_BOOT_CAPTURES)
	capture_boot(t, &f, cl)
	found := false
	for e in queued_errors(cl) {
		if str_of(e, "rs_message") == "the real one" && str_of(e, "rs_severity") == "critical" {
			found = true
		}
	}
	testing.expect(t, found)
	capture_close(cl)
}

@(test)
test_capture_crash_older_than_thirty_days_is_deleted_unsent :: proc(t: ^testing.T) {
	sync.mutex_lock(&capture_test_mutex)
	defer sync.mutex_unlock(&capture_test_mutex)
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	base := strings.concatenate({storage_in(&f), CRASH_FILE_SUFFIX}, context.temp_allocator)
	loc := runtime.Source_Code_Location{file_path = "main.odin", line = 1, column = 1, procedure = "main"}

	a := capture_client(t, &f)
	f.now = T0
	testing.expect(t, capture_persist_crash("panic", "stale", loc))
	f.now = T0 + 2 * 24 * 60 * 60 * 1000
	testing.expect(t, capture_persist_crash("panic", "fresh", loc))
	capture_close(a)

	f.now = T0 + MAX_CRASH_AGE_MS + 1
	b := capture_client(t, &f)
	testing.expect(t, !os.exists(crash_file_path(base, 0)))
	testing.expect(t, os.exists(crash_file_path(base, 1)))
	testing.expect_value(t, len(b.capture.held), 1)
	if len(b.capture.held) == 1 {
		testing.expect_value(t, b.capture.held[0].message, "fresh")
	}
	// An opt-out deletes it at once, not only on the next launch.
	set_tracking_enabled(b, false)
	testing.expect(t, !os.exists(crash_file_path(base, 1)))
	capture_close(b)
}
