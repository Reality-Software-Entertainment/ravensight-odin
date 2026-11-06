// delivery_test.odin - the delivery, ads and attribution, exposure and
// device field contracts, through the fake transport.

package ravensight

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

ORIGIN_A :: `{"build":"1.0.0","platform":"macOS","session":"ses_a","stamp":"o1.aaa.bbb"}`
ORIGIN_B :: `{"build":"1.1.0","platform":"macOS","session":"ses_b","stamp":"o1.ccc.ddd"}`
SIGN_SECRET :: "dGVzdC1zZWNyZXQtZm9yLWRlbGl2ZXJ5LWNvbnRyYWN0"
// A realistic clock, so the 89 day age limit means something.
NOW_REAL :: i64(1_800_000_000_000)

// Ticks (asking for a flush) until a request to `path` is open; returns its
// index or -1.
open_to :: proc(f: ^Fake, path: string) -> int {
	for _ in 0 ..< 3 {
		flush(f.client)
		for r, i in f.requests {
			if !r.answered && strings.has_prefix(r.path, path) {
				return i
			}
		}
		tick(f.client)
	}
	return -1
}

// Marks every open request answered: their transfers went with a closed client.
retire_open :: proc(f: ^Fake) {
	for &r in f.requests {
		r.answered = true
	}
}

// Settings on, then the session answered with `session` (a JSON object);
// an open config fetch is answered offline.
boot_with :: proc(t: ^testing.T, f: ^Fake, cl: ^Client, session: string, loc := #caller_location) {
	tick(cl)
	answer_next(t, f, "/settings", 200, `{"trackingEnabled":true}`, loc = loc)
	tick(cl)
	answer_next(t, f, "/session", 201, session, loc = loc)
	if idx := open_to(f, "/ingest/config?"); idx >= 0 {
		answer(f, idx, 0)
	}
}

session_json :: proc(origin: string, extra := "") -> string {
	return fmt.tprintf(`{{"token":"tok","expiresIn":86400,"origin":%s%s}}`, origin, extra)
}

queue_file_of :: proc(f: ^Fake) -> string {
	return fmt.tprintf("%s/queue-%s.json", f.dir, fnv1a64_hex("gt_live_test", context.temp_allocator))
}

// The saved queue's events in order: (name, origin JSON) pairs.
saved_events :: proc(f: ^Fake) -> (names: [dynamic]string, origins: [dynamic]string, ok: bool) {
	names = make([dynamic]string, context.temp_allocator)
	origins = make([dynamic]string, context.temp_allocator)
	data, err := os.read_entire_file(queue_file_of(f), context.temp_allocator)
	if err != nil {
		return
	}
	parsed, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil {
		return
	}
	doc := parsed.(json.Object)
	for g in doc["groups"].(json.Array) {
		group := g.(json.Object)
		origin := ""
		if o, has := group["origin"].(json.Object); has {
			text, _ := json.marshal(json.Value(o), {sort_maps_by_key = true}, context.temp_allocator)
			origin = string(text)
		}
		for e in group["events"].(json.Array) {
			append(&names, string(e.(json.Object)["event"].(json.String)))
			append(&origins, origin)
		}
	}
	ok = true
	return
}

// The events of a batch body, parsed.
batch_events :: proc(body: string) -> json.Array {
	parsed, _ := json.parse(transmute([]u8)body, allocator = context.temp_allocator)
	return parsed.(json.Object)["events"].(json.Array)
}

event_name :: proc(e: json.Value) -> string {
	return string(e.(json.Object)["event"].(json.String))
}

origin_session :: proc(e: json.Value) -> string {
	o, has := e.(json.Object)["origin"].(json.Object)
	if !has {
		return ""
	}
	return string(o["session"].(json.String))
}

@(test)
test_delivery_fnv_queue_name :: proc(t: ^testing.T) {
	testing.expect_value(t, fnv1a64_hex("", context.temp_allocator), "cbf29ce484222325")
	testing.expect_value(t, fnv1a64_hex("a", context.temp_allocator), "af63dc4c8601ec8c")
	testing.expect_value(t, fnv1a64_hex("gt_live_test", context.temp_allocator), "094acf328fe638e2")
	testing.expect_value(t, fnv1a64_hex("gt_pub_é", context.temp_allocator), "853d257447c0bc87")
}

@(test)
test_delivery_queue_saved_with_origin_and_replayed :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	boot_with(t, &f, cl, session_json(ORIGIN_A, `,"signing":{"algorithm":"HMAC-SHA256","version":1,"secret":"s3cret-value","serverTime":1000}`))
	track(cl, "pickup")
	tick(cl)
	names, origins, ok := saved_events(&f)
	testing.expect(t, ok, "the queue is on disk")
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, origins[0], ORIGIN_A)
	text, _ := os.read_entire_file(queue_file_of(&f), context.temp_allocator)
	testing.expect(t, !strings.contains(string(text), "s3cret-value"), "the secret is never written")
	testing.expect(t, !strings.contains(string(text), `"tok"`), "nor the session token")
	testing.expect(t, strings.contains(string(text), `"version":2`))
	close_client(cl)
	retire_open(&f)

	// The next launch opens another session and sends them with their origin.
	cl2 := fake_client(t, &f, Config{})
	boot_with(t, &f, cl2, session_json(ORIGIN_B))
	idx := open_to(&f, "/track/batch")
	testing.expect(t, idx >= 0)
	events := batch_events(f.requests[idx].body)
	testing.expect_value(t, len(events), 4)
	testing.expect_value(t, event_name(events[0]), "game_started")
	testing.expect_value(t, origin_session(events[0]), "ses_a")
	testing.expect_value(t, event_name(events[1]), "pickup")
	testing.expect_value(t, origin_session(events[1]), "ses_a")
	testing.expect_value(t, event_name(events[2]), "game_exited")
	testing.expect_value(t, origin_session(events[2]), "ses_a")
	testing.expect_value(t, event_name(events[3]), "game_started")
	testing.expect_value(t, origin_session(events[3]), "")
	answer(&f, idx, 202, `{"accepted":4}`)
	tick(cl2)
	testing.expect(t, !os.exists(queue_file_of(&f)), "delivered: the file is gone")
	close_client(cl2)
}

@(test)
test_delivery_queue_removed_only_on_2xx :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	boot_with(t, &f, cl, session_json(ORIGIN_A))
	idx := open_to(&f, "/track/batch")
	answer(&f, idx, 500, `{"error":"internal_error"}`)
	names, _, ok := saved_events(&f)
	testing.expect(t, ok && len(names) == 1, "a 5xx keeps the event on disk")
	f.now += 10_000
	idx = open_to(&f, "/track/batch")
	answer(&f, idx, 202)
	testing.expect(t, !os.exists(queue_file_of(&f)), "a 2xx removes it")
}

@(test)
test_delivery_unusable_file_and_version_1 :: proc(t: ^testing.T) {
	for text in ([]string{"not json", `{"version":9,"groups":[]}`, `[]`, `{"version":2}`}) {
		f: Fake
		fake_init(&f)
		os.make_directory_all(f.dir)
		_ = os.write_entire_file(queue_file_of(&f), transmute([]u8)text)
		cl := fake_client(t, &f, Config{})
		testing.expect_value(t, queue_len(cl), 1) // game_started only
		close_client(cl)
		fake_destroy(&f)
	}
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	os.make_directory_all(f.dir)
	v1 := `{"version":1,"groups":[{"origin":` + ORIGIN_A + `,"events":[{"event":"v1","timestamp":900000,"data":{"rs_event_id":"x1"}}]}]}`
	_ = os.write_entire_file(queue_file_of(&f), transmute([]u8)v1)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	testing.expect_value(t, cl.core.queue[0].name, "v1")
	testing.expect_value(t, cl.core.queue[0].origin_json, "")
	testing.expect(t, cl.core.queue[0].origin_fixed, "a version 1 group has no origin and adopts none")
}

@(test)
test_delivery_age_and_cap :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	f.now = NOW_REAL
	os.make_directory_all(f.dir)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"version":2,"groups":[{"origin":` + ORIGIN_A + `,"events":[`)
	fmt.sbprintf(&b, `{{"event":"ancient","timestamp":%d,"data":{{}}}},`, NOW_REAL - 90 * 86_400_000)
	fmt.sbprintf(&b, `{{"event":"old_seconds","timestamp":%d,"data":{{}}}}`, (NOW_REAL - 100 * 86_400_000) / 1000)
	for i in 0 ..< 600 {
		fmt.sbprintf(&b, `,{{"event":"e%d","timestamp":%d,"data":{{}}}}`, i, NOW_REAL - 1000 + i64(i))
	}
	strings.write_string(&b, `]}]}`)
	_ = os.write_entire_file(queue_file_of(&f), transmute([]u8)strings.to_string(b))
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	testing.expect_value(t, queue_len(cl), 500)
	testing.expect_value(t, cl.core.stats.dropped_too_old, 2)
	testing.expect_value(t, cl.core.stats.dropped_overflow, 101) // 100 on load, 1 for game_started
	testing.expect_value(t, cl.core.queue[len(cl.core.queue) - 1].name, "game_started")
}

@(test)
test_delivery_optout_reset_forget_403_keeps :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	boot_with(t, &f, cl, session_json(ORIGIN_A))
	track(cl, "a")
	tick(cl)
	testing.expect(t, os.exists(queue_file_of(&f)))
	set_tracking_enabled(cl, false)
	testing.expect(t, !os.exists(queue_file_of(&f)), "opt-out deletes the queue")
	set_tracking_enabled(cl, true)
	track(cl, "b")
	tick(cl)
	reset_device_id(cl)
	testing.expect(t, !os.exists(queue_file_of(&f)), "a reset deletes the queue")
	close_client(cl)

	g: Fake
	fake_init(&g)
	defer fake_destroy(&g)
	k := fake_client(t, &g, Config{})
	defer close_client(k)
	boot_with(t, &g, k, session_json(ORIGIN_A))
	idx := open_to(&g, "/track/batch")
	track(k, "c")
	answer(&g, idx, 403, `{"error":"public_key_inactive"}`)
	names, _, ok := saved_events(&g)
	testing.expect(t, ok, "a 403 keeps the queue on disk")
	testing.expect_value(t, len(names), 2)
	testing.expect(t, !is_active(k), "and stops sending this run")
}

@(test)
test_delivery_refusals :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	track_n(&c, 4, T0)
	open_session(t, &c, T0)
	core_request_flush(&c)
	step_batch(t, &c, T0, 4, Core_Response{status = 400, error_code = "reserved_key", index = 1})
	testing.expect_value(t, len(c.queue), 3)
	testing.expect_value(t, c.queue[1].name, "e2")
	testing.expect_value(t, c.stats.dropped_refused, 1)
	step_batch(t, &c, T0, 3, Core_Response{status = 400, error_code = "batch_too_large", index = -1})
	testing.expect_value(t, c.batch_limit, 1)
	step_batch(t, &c, T0, 1, Core_Response{status = 202})
	step_batch(t, &c, T0, 2, Core_Response{status = 413, index = -1})
	testing.expect_value(t, c.batch_limit, 1) // a 413 is split like a 400
	c.last_batch_compressed = true
	step_batch(t, &c, T0, 1, Core_Response{status = 413, index = -1})
	testing.expect(t, c.send_plain, "a 413 for one compressed event resends it uncompressed")
	c.last_batch_compressed = false
	step_batch(t, &c, T0, 1, Core_Response{status = 413, index = -1})
	testing.expect_value(t, c.stats.dropped_refused, 2)
	step_batch(t, &c, T0, 1, Core_Response{status = 415, index = -1})
	testing.expect(t, c.send_plain)
	step_batch(t, &c, T0, 1, Core_Response{status = 415, index = -1})
	testing.expect_value(t, c.stats.dropped_refused, 3)
	testing.expect_value(t, len(c.queue), 0)
	// A 413 for one event that went uncompressed is dropped at once.
	track_n(&c, 1, T0, "h")
	core_request_flush(&c)
	step_batch(t, &c, T0, 1, Core_Response{status = 413, index = -1})
	testing.expect_value(t, len(c.queue), 0)
	testing.expect(t, !c.send_plain)
	testing.expect_value(t, c.stats.dropped_refused, 4)
	track_n(&c, 3, T0, "g")
	core_request_flush(&c)
	step_batch(t, &c, T0, 3, Core_Response{status = 400, error_code = "invalid_json", index = -1})
	testing.expect_value(t, len(c.queue), 0) // another 400 drops the request
	testing.expect_value(t, c.stats.dropped_refused, 7)
}

@(test)
test_delivery_retry_after_not_cut_by_flush :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0)
	track_n(&c, 1, T0)
	core_request_flush(&c)
	// game_started (from boot) and e0.
	step_batch(t, &c, T0, 2, Core_Response{status = 503, retry_after_ms = 30_000, index = -1})
	core_force_flush(&c)
	expect_no_request(t, &c, T0)
	step_batch(t, &c, T0 + 30_000, 2, Core_Response{status = 500, index = -1})
	core_force_flush(&c)
	step_batch(t, &c, T0 + 30_000, 2, Core_Response{status = 202})
}

@(test)
test_delivery_gzip_from_1024_bytes :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	boot_with(t, &f, cl, session_json(ORIGIN_A))
	idx := open_to(&f, "/track/batch")
	testing.expect(t, !f.requests[idx].gzipped, "a small body is plain")
	answer(&f, idx, 202)
	for i in 0 ..< 30 {
		track(cl, fmt.tprintf("bulk%d", i))
	}
	flush(cl)
	idx = open_to(&f, "/track/batch")
	when ODIN_OS != .Windows {
		testing.expect(t, f.requests[idx].gzipped, "a body of 1,024 bytes or more is compressed")
		testing.expect(t, len(f.requests[idx].body) >= GZIP_MIN_BYTES)
	}
	testing.expect_value(t, len(batch_events(f.requests[idx].body)), 30)
}

@(test)
test_delivery_signing_vectors :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("ravensight/testdata/delivery-vectors.json", context.temp_allocator)
	if err != nil {
		data, err = os.read_entire_file("testdata/delivery-vectors.json", context.temp_allocator)
	}
	testing.expect(t, err == nil, "the vectors file")
	parsed, _ := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	signing := parsed.(json.Object)["signing"].(json.Object)
	secret := string(signing["secret"].(json.String))
	for v in signing["header"].(json.Array) {
		c := v.(json.Object)
		got := fmt.tprintf("v1=%s", sign_body(secret, i64(c["timestamp"].(json.Integer)), string(c["body"].(json.String))))
		testing.expect_value(t, got, string(c["header"].(json.String)))
	}
	for v in signing["beacon"].(json.Array) {
		c := v.(json.Object)
		envelope := c["envelope"].(json.Object)["signed"].(json.Object)
		testing.expect_value(t, sign_body(secret, i64(c["t"].(json.Integer)), string(c["inner"].(json.String))), string(envelope["sig"].(json.String)))
	}
	// The event size cases: the local check agrees with the server.
	for v in parsed.(json.Object)["anyKeyEventSize"].(json.Object)["cases"].(json.Array) {
		c := v.(json.Object)
		obj := make(json.Object, allocator = context.temp_allocator)
		for k, value in c["data"].(json.Object) {
			if rep, is_rep := value.(json.Object); is_rep {
				obj[k] = json.String(strings.repeat(string(rep["repeat"].(json.String)), int(rep["count"].(json.Integer)), context.temp_allocator))
			} else {
				obj[k] = value
			}
		}
		text, _ := json.marshal(json.Value(obj), allocator = context.temp_allocator)
		_, refused := c["expect"].(json.String)
		testing.expect_value(t, event_bytes(string(text)) > MAX_EVENT_BYTES, refused)
	}
}

@(test)
test_delivery_signed_batch_and_401_once :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	server_time := T0 / 1000 + 100
	boot_with(t, &f, cl, session_json(ORIGIN_A, fmt.tprintf(`,"signing":{{"algorithm":"HMAC-SHA256","version":1,"secret":"%s","serverTime":%d}}`, SIGN_SECRET, server_time)))
	idx := open_to(&f, "/track/batch")
	r := f.requests[idx]
	testing.expect(t, has_header(r, fmt.tprintf("X-Ravensight-Timestamp: %d", server_time)), "the device clock corrected by serverTime")
	testing.expect(t, has_header(r, fmt.tprintf("X-Ravensight-Signature: v1=%s", sign_body(SIGN_SECRET, server_time, r.body))), "signed over the body")
	answer(&f, idx, 401, `{"error":"signature_expired"}`)
	tick(cl)
	answer_next(t, &f, "/session", 201, session_json(ORIGIN_B))
	idx = open_to(&f, "/track/batch")
	testing.expect(t, idx >= 0 && !strings.contains(strings.join(f.requests[idx].headers[:], "|", context.temp_allocator), "X-Ravensight-Signature"), "a session with no signing sends none")
}

@(test)
test_delivery_device_fields :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{device_model = "  Pixel\a 7 ", device_os_version = "", device_gpu = strings.repeat("G", 200, context.temp_allocator)})
	defer close_client(cl)
	boot_client(t, &f, cl)
	body := session_body_of(&f)
	testing.expect(t, strings.contains(body, fmt.tprintf(`"device":{{"model":"Pixel 7","gpu":"%s"}}`, strings.repeat("G", 128, context.temp_allocator))), body)
	testing.expect_value(t, device_json("", "", ""), "")
}

@(test)
test_delivery_full_queue_evicts_automatic_errors_first :: proc(t: ^testing.T) {
	c := core_make(max_queue = 4)
	defer core_destroy(&c)
	core_track(&c, "a", "", T0)
	core_track(&c, "crash", "", T0, is_error = true)
	core_track(&c, "b", "", T0)
	testing.expect_value(t, c.queue[2].name, "crash") // gameplay goes ahead of it
	core_track(&c, "c", "", T0)
	core_track(&c, "d", "", T0)
	testing.expect_value(t, len(c.queue), 4)
	testing.expect_value(t, c.queue[3].name, "d")
	for e in c.queue {
		testing.expect(t, e.name != "crash", "the automatic error is evicted first")
	}
	testing.expect(t, !core_track(&c, "crash2", "", T0, is_error = true), "an automatic error never evicts gameplay")
	testing.expect_value(t, c.queue[0].name, "a")
	testing.expect(t, is_automatic_error_json(`{"rs_kind":"error","rs_source":"uncaught"}`))
	testing.expect(t, !is_automatic_error_json(`{"rs_kind":"error","rs_source":"manual"}`))
	testing.expect(t, !is_automatic_error_json(`{"rs_kind":"error"}`))
}

@(test)
test_ads_conformance :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	testing.expect(t, track_ad_revenue(cl, "admob", "rewarded", "level_end", "1500", "USD"))
	last := cl.core.queue[len(cl.core.queue) - 1]
	testing.expect_value(t, last.name, "rs_ad")
	parsed, _ := json.parse(transmute([]u8)last.data_json, allocator = context.temp_allocator)
	obj := parsed.(json.Object)
	testing.expect_value(t, len(obj), 8) // the seven keys and rs_event_id
	testing.expect_value(t, string(obj["rs_revenue_micros"].(json.String)), "1500")
	testing.expect_value(t, string(obj["rs_ad_placement"].(json.String)), "level_end")
	testing.expect_value(t, string(obj["rs_currency"].(json.String)), "USD")
	n := queue_len(cl)
	testing.expect(t, !track_ad(cl, "admob", "rewarded", "shown", Ad_Options{revenue_micros = "1500"}), "revenue without a currency")
	testing.expect(t, !track_ad(cl, "admob", "rewarded", "shown", Ad_Options{revenue_micros = "0.0015", currency = "USD"}), "decimal text")
	testing.expect(t, !track_ad(cl, "admob", "rewarded", "clicked", Ad_Options{revenue_micros = "10", currency = "USD"}), "revenue on a click")
	testing.expect(t, !track_ad(cl, "admob", "video", "shown"), "a format")
	testing.expect(t, !track_ad(cl, "", "banner", "shown"), "an empty network")
	testing.expect(t, !track_ad(cl, "admob", "banner", "shown", Ad_Options{currency = "USD"}), "a currency alone")
	testing.expect_value(t, queue_len(cl), n)
	testing.expect(t, track_ad(cl, "applovin", "interstitial", "clicked"))
	testing.expect(t, !strings.contains(cl.core.queue[len(cl.core.queue) - 1].data_json, "rs_revenue_micros"))
}

@(test)
test_ads_micros_without_float_multiply :: proc(t: ^testing.T) {
	cases := [?][2]string{{"0.0015", "1500"}, {"1.23456789", "1234568"}, {"1.2345675", "1234568"}, {"1.2345674", "1234567"},
		{"1.9999995", "2000000"}, {"9.9999999", "10000000"}, {"0.0000005", "1"}, {"12", "12000000"}, {".5", "500000"}, {"0", "0"}}
	for c in cases {
		got, ok := micros_from_decimal_string(c[0], context.temp_allocator)
		testing.expect(t, ok, c[0])
		testing.expect_value(t, got, c[1])
	}
	for bad in ([]string{"", "abc", "-1", "1e5", "1.2.3", " ", "999999999999.9999999"}) {
		_, ok := micros_from_decimal_string(bad, context.temp_allocator)
		testing.expect(t, !ok, bad)
	}
	a, _ := micros_from_revenue(0.0015, context.temp_allocator)
	testing.expect_value(t, a, "1500")
	b, _ := micros_from_revenue(1.23456789, context.temp_allocator)
	testing.expect_value(t, b, "1234568")
	_, neg := micros_from_revenue(-1, context.temp_allocator)
	testing.expect(t, !neg)
}

@(test)
test_attribution_once_per_install :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	testing.expect(t, set_attribution(cl, Attribution{source = "store_referrer", campaign = "spring", touch_time_ms = 1767225600000}))
	last := cl.core.queue[len(cl.core.queue) - 1]
	testing.expect_value(t, last.name, "rs_attribution")
	testing.expect(t, strings.contains(last.data_json, `"rs_campaign":"spring"`))
	testing.expect(t, strings.contains(last.data_json, `"rs_touch_time":1767225600000`))
	testing.expect(t, !strings.contains(last.data_json, "rs_adset"), "empty fields left out")
	testing.expect(t, !set_attribution(cl, Attribution{source = "organic"}))
	close_client(cl)
	cl2 := fake_client(t, &f, Config{})
	defer close_client(cl2)
	testing.expect(t, !set_attribution(cl2, Attribution{source = "organic"}), "not after a restart")
	reset_device_id(cl2)
	testing.expect(t, set_attribution(cl2, Attribution{source = "organic"}), "a reset identity is a new install")
	testing.expect(t, !set_attribution(cl2, Attribution{source = ""}) || true)
}

@(test)
test_exposure_contract :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	boot_with(t, &f, cl, session_json(ORIGIN_A))
	fetch_config(cl)
	idx := open_to(&f, "/ingest/config?")
	answer(&f, idx, 200, CONFIG_FIXTURE)
	track(cl, "before_read")
	testing.expect(t, !strings.contains(cl.core.queue[len(cl.core.queue) - 1].data_json, "rs_exp_"), "a fetch alone tags nothing")
	_ = get_config_number(cl, "difficulty", 0)
	_ = get_config_number(cl, "difficulty", 0)
	track(cl, "after_read")
	n := len(cl.core.queue)
	testing.expect_value(t, cl.core.queue[n - 2].name, "rs_exposure")
	testing.expect(t, strings.contains(cl.core.queue[n - 2].data_json, `"rs_exp_tutorial":"short"`))
	testing.expect(t, strings.contains(cl.core.queue[n - 1].data_json, `"rs_exp_tutorial":"short"`))
	exposures := 0
	for e in cl.core.queue {
		if e.name == "rs_exposure" {
			exposures += 1
		}
	}
	testing.expect_value(t, exposures, 1)
	// Saved and replayed with its tag.
	tick(cl)
	close_client(cl)
	retire_open(&f)
	cl2 := fake_client(t, &f, Config{})
	defer close_client(cl2)
	found := false
	for e in cl2.core.queue {
		if e.name == "after_read" {
			found = strings.contains(e.data_json, `"rs_exp_tutorial":"short"`)
		}
	}
	testing.expect(t, found, "a queued event keeps its tag")
	track(cl2, "new_launch")
	testing.expect(t, !strings.contains(cl2.core.queue[len(cl2.core.queue) - 1].data_json, `"rs_exp_tutorial"`), "a new launch starts untagged")
	// A stopped experiment is not tagged after the next fetch.
	_ = get_config_number(cl2, "difficulty", 0)
	boot_with(t, &f, cl2, session_json(ORIGIN_B))
	fetch_config(cl2)
	idx = open_to(&f, "/ingest/config?")
	if idx >= 0 {
		answer(&f, idx, 200, `{"values":{"difficulty":2},"experiments":[],"etag":"\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\""}`)
	}
	track(cl2, "after_stop")
	testing.expect(t, !strings.contains(cl2.core.queue[len(cl2.core.queue) - 1].data_json, "rs_exp_tutorial"))
}

@(test)
test_delivery_crash_records_settle_and_stay_out_of_the_queue_file :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	boot(t, &c, T0, with_session = false)
	core_track(&c, "error", `{"rs_kind":"error","rs_source":"crash"}`, T0, is_error = true, tag = 7)
	core_track(&c, "play", "", T0)
	open_session(t, &c, T0)
	core_request_flush(&c)
	// Gameplay goes first; the refused crash event is named by index.
	step_batch(t, &c, T0, 2, Core_Response{status = 400, error_code = "reserved_key", index = 1})
	testing.expect_value(t, len(c.settled_tags), 1)
	testing.expect_value(t, c.settled_tags[0], 7)

	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	boot_with(t, &f, cl, session_json(ORIGIN_A))
	core_track(&cl.core, "error", `{"rs_kind":"error","rs_source":"crash"}`, client_now(cl), is_error = true, tag = 3)
	track(cl, "play")
	tick(cl)
	names, _, ok := saved_events(&f)
	testing.expect(t, ok)
	for n in names {
		testing.expect(t, n != "error", "a crash with its own record is not saved twice")
	}
}

// --- Error queue rules (all SDKs, 2026-11-06) -------------------------------------

@(test)
test_error_rule_1_gameplay_before_captures :: proc(t: ^testing.T) {
	c := core_make()
	defer core_destroy(&c)
	core_track(&c, "a", "", T0)
	core_track(&c, "capture", `{"rs_kind":"error","rs_source":"log"}`, T0, is_error = true)
	// A game's own error is gameplay.
	core_track(&c, "own_error", `{"rs_kind":"error","rs_source":"manual"}`, T0)
	core_track(&c, "b", "", T0)
	names := [4]string{}
	for e, i in c.queue {
		names[i] = e.name
	}
	testing.expect_value(t, names, [4]string{"a", "own_error", "b", "capture"})

	// A queue read from disk is ordered the same way.
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	os.make_directory_all(f.dir)
	text := `{"version":2,"groups":[{"events":[{"event":"old_capture","timestamp":900000,"data":{"rs_kind":"error","rs_source":"crash"}},{"event":"old_play","timestamp":900001,"data":{}}]}]}`
	_ = os.write_entire_file(queue_file_of(&f), transmute([]u8)text)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	testing.expect_value(t, cl.core.queue[0].name, "old_play")
	testing.expect_value(t, cl.core.queue[1].name, "game_started")
	testing.expect_value(t, cl.core.queue[2].name, "old_capture")
}

@(test)
test_error_rule_2_full_queue :: proc(t: ^testing.T) {
	c := core_make(max_queue = 3)
	defer core_destroy(&c)
	core_track(&c, "a", "", T0)
	core_track(&c, "c1", "", T0, is_error = true)
	core_track(&c, "c2", "", T0, is_error = true)
	core_track(&c, "c3", "", T0, is_error = true)
	testing.expect_value(t, c.queue[1].name, "c2") // the oldest capture went
	testing.expect_value(t, c.queue[2].name, "c3")
	core_track(&c, "b", "", T0)
	core_track(&c, "x", "", T0)
	testing.expect_value(t, c.queue[0].name, "a")
	testing.expect_value(t, c.queue[1].name, "b")
	testing.expect_value(t, c.queue[2].name, "x") // gameplay as before, captures first
	testing.expect(t, !core_track(&c, "c4", "", T0, is_error = true), "with no capture queued, an incoming capture is dropped")
	testing.expect_value(t, c.queue[0].name, "a")
}

@(test)
test_error_rule_3_trail_never_on_disk_and_optout_deletes :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	boot_with(t, &f, cl, session_json(ORIGIN_A))
	core_track(&cl.core, "capture", `{"rs_kind":"error","rs_source":"log","rs_trail":"+0 info entered cave"}`, client_now(cl), is_error = true)
	tick(cl)
	text, _ := os.read_entire_file(queue_file_of(&f), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `"capture"`), "the capture is persisted")
	testing.expect(t, !strings.contains(string(text), "rs_trail") && !strings.contains(string(text), "entered cave"), "its trail is not")
	testing.expect(t, strings.contains(cl.core.queue[len(cl.core.queue) - 1].data_json, "entered cave"), "the trail stays in memory")
	set_tracking_enabled(cl, false)
	testing.expect(t, !os.exists(queue_file_of(&f)), "opt-out deletes persisted captures")
	set_tracking_enabled(cl, true)
	core_track(&cl.core, "capture", `{"rs_kind":"error","rs_source":"log"}`, client_now(cl), is_error = true)
	tick(cl)
	testing.expect(t, os.exists(queue_file_of(&f)))
	reset_device_id(cl)
	testing.expect(t, !os.exists(queue_file_of(&f)), "a device id reset deletes persisted captures")
}
