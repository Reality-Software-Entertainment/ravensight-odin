// typed_test.odin - the typed event helpers and the health summary, through
// the same fake transport as client_test.odin. Properties are read back from
// the queued event's JSON, so the tests see exactly what would be sent.

package ravensight

import "core:encoding/json"
import "core:strings"
import "core:testing"

// The last queued event's name and parsed data.
last_event :: proc(t: ^testing.T, cl: ^Client) -> (name: string, obj: json.Object) {
	testing.expect(t, len(cl.core.queue) > 0)
	if len(cl.core.queue) == 0 {
		return "", nil
	}
	evt := cl.core.queue[len(cl.core.queue) - 1]
	val, err := json.parse(transmute([]u8)evt.data_json, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	o, _ := val.(json.Object)
	id, has_id := o["rs_event_id"]
	testing.expect(t, has_id)
	testing.expect(t, len(string(id.(json.String))) > 0)
	delete_key(&o, "rs_event_id")
	return evt.name, o
}

expect_str :: proc(t: ^testing.T, o: json.Object, key, want: string, loc := #caller_location) {
	v, ok := o[key]
	testing.expect(t, ok, key, loc = loc)
	s, is_str := v.(json.String)
	testing.expect(t, is_str, key, loc = loc)
	testing.expect_value(t, string(s), want, loc = loc)
}

expect_num :: proc(t: ^testing.T, o: json.Object, key: string, want: f64, loc := #caller_location) {
	v, ok := o[key]
	testing.expect(t, ok, key, loc = loc)
	n: f64
	#partial switch x in v {
	case json.Float:
		n = f64(x)
	case json.Integer:
		n = f64(x)
	case:
		testing.expectf(t, false, "%s is not a number", key, loc = loc)
	}
	testing.expect_value(t, n, want, loc = loc)
}

typed_client :: proc(t: ^testing.T, f: ^Fake, cfg: Config = {}) -> ^Client {
	fake_init(f)
	return fake_client(t, f, cfg)
}

@(test)
test_typed_purchase_exact_properties :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	testing.expect(t, track_purchase(cl, 499, "usd", "bundle", "starter", cart = "c1", transaction_id = "tx9"))
	name, o := last_event(t, cl)
	testing.expect_value(t, name, "purchase")
	testing.expect_value(t, len(o), 7)
	expect_str(t, o, "rs_kind", "purchase")
	expect_num(t, o, "rs_amount", 499)
	expect_str(t, o, "rs_currency", "USD")
	expect_str(t, o, "rs_item_type", "bundle")
	expect_str(t, o, "rs_item_id", "starter")
	expect_str(t, o, "rs_cart", "c1")
	expect_str(t, o, "rs_transaction_id", "tx9")
	close_client(cl)
}

@(test)
test_typed_purchase_optionals_left_out_and_digit_string_amount :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	testing.expect(t, track_purchase(cl, "1999", "eur", "skin", "red"))
	_, o := last_event(t, cl)
	testing.expect_value(t, len(o), 5)
	expect_str(t, o, "rs_amount", "1999")
	expect_str(t, o, "rs_currency", "EUR")
	testing.expect(t, "rs_cart" not_in o)
	testing.expect(t, "rs_transaction_id" not_in o)
	close_client(cl)
}

@(test)
test_typed_bad_input_passes_through :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	// A float amount and a two letter currency are sent as given; the
	// server flags them.
	testing.expect(t, track_purchase(cl, 4.99, "us", "", ""))
	_, o := last_event(t, cl)
	expect_num(t, o, "rs_amount", 4.99)
	expect_str(t, o, "rs_currency", "US")
	close_client(cl)
}

@(test)
test_typed_resource_flow_names_and_properties :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	testing.expect(t, track_resource(cl, FLOW_SOURCE, "gold", 25, item_type = "chest", item_id = "c7"))
	name, o := last_event(t, cl)
	testing.expect_value(t, name, "resource_source")
	testing.expect_value(t, len(o), 6)
	expect_str(t, o, "rs_kind", "resource")
	expect_str(t, o, "rs_flow", "source")
	expect_str(t, o, "rs_resource", "gold")
	expect_num(t, o, "rs_amount", 25)
	expect_str(t, o, "rs_item_type", "chest")
	expect_str(t, o, "rs_item_id", "c7")

	testing.expect(t, track_resource(cl, FLOW_SINK, "gold", 10.5))
	name, o = last_event(t, cl)
	testing.expect_value(t, name, "resource_sink")
	testing.expect_value(t, len(o), 4)
	expect_num(t, o, "rs_amount", 10.5)
	testing.expect(t, "rs_item_type" not_in o)
	testing.expect(t, "rs_item_id" not_in o)
	close_client(cl)
}

@(test)
test_typed_progression_names_and_properties :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	testing.expect(t, track_progression(cl, STATUS_COMPLETE, "world1", "level3", "boss", score = 1200))
	name, o := last_event(t, cl)
	testing.expect_value(t, name, "progression_complete")
	testing.expect_value(t, len(o), 6)
	expect_str(t, o, "rs_kind", "progression")
	expect_str(t, o, "rs_status", "complete")
	expect_str(t, o, "rs_p1", "world1")
	expect_str(t, o, "rs_p2", "level3")
	expect_str(t, o, "rs_p3", "boss")
	expect_num(t, o, "rs_score", 1200)

	testing.expect(t, track_progression(cl, STATUS_START, "world1"))
	name, o = last_event(t, cl)
	testing.expect_value(t, name, "progression_start")
	testing.expect_value(t, len(o), 3)
	testing.expect(t, "rs_score" not_in o)

	testing.expect(t, track_progression(cl, STATUS_FAIL, "world1", "level3"))
	name, _ = last_event(t, cl)
	testing.expect_value(t, name, "progression_fail")
	close_client(cl)
}

@(test)
test_typed_error_properties_and_cuts :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	testing.expect(t, track_error(cl, SEVERITY_WARNING, "low memory"))
	name, o := last_event(t, cl)
	testing.expect_value(t, name, "error")
	testing.expect_value(t, len(o), 3)
	expect_str(t, o, "rs_kind", "error")
	expect_str(t, o, "rs_severity", "warning")
	expect_str(t, o, "rs_message", "low memory")
	testing.expect(t, "rs_stack" not_in o)

	long_msg := strings.repeat("m", 450, context.temp_allocator)
	long_stack := strings.repeat("s", 3000, context.temp_allocator)
	testing.expect(t, track_error(cl, SEVERITY_CRITICAL, long_msg, long_stack))
	_, o = last_event(t, cl)
	testing.expect_value(t, len(o), 4)
	expect_str(t, o, "rs_message", strings.repeat("m", 200, context.temp_allocator))
	expect_str(t, o, "rs_stack", strings.repeat("s", 2000, context.temp_allocator))

	// Cut by code point, never through a multi-byte character.
	wide := strings.repeat("é", 300, context.temp_allocator)
	testing.expect(t, track_error(cl, SEVERITY_ERROR, wide))
	_, o = last_event(t, cl)
	expect_str(t, o, "rs_message", strings.repeat("é", 200, context.temp_allocator))
	close_client(cl)
}

@(test)
test_typed_extra_merges_first_and_reserved_keys_win :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	extra := make(Extra, allocator = context.temp_allocator)
	extra["rs_kind"] = json.String("none")
	extra["rs_currency"] = json.String("ZZZ")
	extra["level"] = json.String("castle")
	testing.expect(t, track_purchase(cl, 100, "usd", "gem", "g1", extra = extra))
	_, o := last_event(t, cl)
	expect_str(t, o, "rs_kind", "purchase")
	expect_str(t, o, "rs_currency", "USD")
	expect_str(t, o, "level", "castle")
	close_client(cl)
}

@(test)
test_typed_event_name_override :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	testing.expect(t, track_purchase(cl, 100, "usd", "gem", "g1", name = "iap"))
	testing.expect(t, track_resource(cl, FLOW_SINK, "gold", 1, name = "spend"))
	testing.expect(t, track_progression(cl, STATUS_START, "a", name = "begin_run"))
	testing.expect(t, track_error(cl, SEVERITY_INFO, "x", name = "oops"))
	names := [4]string{"iap", "spend", "begin_run", "oops"}
	for want, i in names {
		testing.expect_value(t, cl.core.queue[len(cl.core.queue) - 4 + i].name, want)
	}
	close_client(cl)
}

@(test)
test_typed_helpers_return_track_result :: proc(t: ^testing.T) {
	testing.expect(t, !track_purchase(nil, 1, "usd", "a", "b"))
	f: Fake
	cl := typed_client(t, &f, Config{start_disabled = true})
	defer fake_destroy(&f)
	testing.expect(t, !track_error(cl, SEVERITY_INFO, "off"))
	testing.expect(t, !track_resource(cl, FLOW_SOURCE, "gold", 1))
	close_client(cl)
}

@(test)
test_typed_helpers_carry_playtest_tags :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f, Config{playtest_token = "pt_tok", playtest_run_id = "run1", playtest_job_id = "job1", playtest_persona = "casual"})
	defer fake_destroy(&f)
	testing.expect(t, track_error(cl, SEVERITY_INFO, "hello"))
	_, o := last_event(t, cl)
	expect_str(t, o, "rs_kind", "error")
	expect_str(t, o, "pt_source", "sdk")
	close_client(cl)
}

// --- Health ---------------------------------------------------------------------

@(test)
test_health_summary_percentiles_from_known_samples :: proc(t: ^testing.T) {
	_, _, ok := health_summary(nil)
	testing.expect(t, !ok)

	odd := []f64{30, 10, 20, 50, 40}
	median, p10, ok2 := health_summary(odd)
	testing.expect(t, ok2)
	testing.expect_value(t, median, 30.0)
	testing.expect_value(t, p10, 10.0)
	testing.expect_value(t, odd[0], 30.0) // input untouched

	hundred: [100]f64
	for i in 0 ..< 100 {
		hundred[i] = f64(100 - i)
	}
	median, p10, _ = health_summary(hundred[:])
	testing.expect_value(t, median, 50.5)
	testing.expect_value(t, p10, 10.0)
}

health_events :: proc(f: ^Fake) -> (count: int) {
	for r in f.requests {
		count += strings.count(r.body, `"rs_kind":"health"`)
	}
	return
}

@(test)
test_health_sent_once_from_shutdown_with_known_percentiles :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f, Config{performance = true})
	defer fake_destroy(&f)
	boot_client(t, &f, cl)
	// Ten seconds, one frame each at 10, 20, ... 100 fps.
	for i in 1 ..= 10 {
		f.now += 1_000
		tick(cl, 1.0 / f64(i * 10))
	}
	testing.expect_value(t, len(cl.health_samples), 10)
	// Nothing is sent from tick().
	for e in cl.core.queue {
		testing.expect(t, e.name != "health")
	}
	f.auto = proc(path: string) -> (int, string) {
		return 202, `{"accepted":1}`
	}
	shutdown(cl)
	testing.expect_value(t, health_events(&f), 1)
	for r in f.requests {
		if strings.contains(r.body, `"health"`) {
			testing.expect(t, strings.contains(r.body, `"rs_fps_median":55`))
			testing.expect(t, strings.contains(r.body, `"rs_fps_p10":10`))
			testing.expect(t, strings.contains(r.body, `"rs_boot_ms":`))
		}
	}
}

@(test)
test_health_samples_once_per_second_only :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f, Config{performance = true})
	defer fake_destroy(&f)
	for _ in 0 ..< 100 {
		f.now += 16
		tick(cl, 0.016)
	}
	testing.expect_value(t, len(cl.health_samples), 1)
	close_client(cl)
}

@(test)
test_health_without_dt_measures_between_ticks :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f, Config{performance = true})
	defer fake_destroy(&f)
	f.now += 1_000
	tick(cl) // first tick has no previous frame
	testing.expect_value(t, len(cl.health_samples), 0)
	f.now += 1_000
	tick(cl) // 1000 ms since the last tick: one frame per second
	testing.expect_value(t, len(cl.health_samples), 1)
	testing.expect_value(t, cl.health_samples[0], 1.0)
	close_client(cl)
}

@(test)
test_health_reservoir_is_bounded :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f, Config{performance = true})
	defer fake_destroy(&f)
	for _ in 0 ..< MAX_HEALTH_SAMPLES + 50 {
		f.now += 1_000
		tick(cl, 0.02)
	}
	testing.expect_value(t, len(cl.health_samples), MAX_HEALTH_SAMPLES)
	close_client(cl)
}

@(test)
test_health_nothing_without_samples_or_opt_in :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f, Config{performance = true})
	defer fake_destroy(&f)
	boot_client(t, &f, cl)
	f.auto = proc(path: string) -> (int, string) {
		return 202, `{"accepted":1}`
	}
	shutdown(cl) // no sample was ever taken
	testing.expect_value(t, health_events(&f), 0)

	f2: Fake
	cl2 := typed_client(t, &f2) // performance off
	defer fake_destroy(&f2)
	boot_client(t, &f2, cl2)
	for _ in 0 ..< 5 {
		f2.now += 1_000
		tick(cl2, 0.016)
	}
	testing.expect_value(t, len(cl2.health_samples), 0)
	f2.auto = proc(path: string) -> (int, string) {
		return 202, `{"accepted":1}`
	}
	shutdown(cl2)
	testing.expect_value(t, health_events(&f2), 0)
}

@(test)
test_session_request_carries_sdk_name_and_version :: proc(t: ^testing.T) {
	f: Fake
	cl := typed_client(t, &f)
	defer fake_destroy(&f)
	tick(cl)
	answer_next(t, &f, "/settings", 200, `{"trackingEnabled":true}`)
	tick(cl)
	idx := open_request(&f)
	testing.expect_value(t, f.requests[idx].path, "/session")
	testing.expect(t, strings.contains(f.requests[idx].body, `"sdk":"odin/0.3.0"`))
	close_client(cl)
}

@(test)
test_cut_runes :: proc(t: ^testing.T) {
	testing.expect_value(t, cut_runes("abc", 5), "abc")
	testing.expect_value(t, cut_runes("abc", 3), "abc")
	testing.expect_value(t, cut_runes("abcd", 3), "abc")
	testing.expect_value(t, cut_runes("ééé", 2), "éé")
	testing.expect_value(t, cut_runes("", 2), "")
}
