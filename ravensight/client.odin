// client.odin - the public Ravensight API.
//
// A Client owns one pure protocol state machine (core.odin) and one libcurl
// multi handle. Nothing here blocks: tick(), called once per frame from the
// game's main loop, pumps curl, feeds finished responses into the core and
// starts whatever request the core asks for next. shutdown() performs one
// bounded, best-effort final flush.

package ravensight

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:time"

VERSION :: "0.1.0"
DEFAULT_API_URL :: "https://api.ravensight.io/api/v1"
DEFAULT_REQUEST_TIMEOUT_MS :: 15_000

Error :: enum {
	None,
	Missing_Ingest_Key,
	Curl_Init_Failed,
}

// All callbacks are optional and are invoked from inside tick() (or
// shutdown()), on the calling thread. `user` is passed through untouched.
Callbacks :: struct {
	user:                  rawptr,
	on_session_ready:      proc(user: rawptr),
	on_session_failed:     proc(user: rawptr, reason: string),
	on_tracking_disabled:  proc(user: rawptr),
	on_events_flushed:     proc(user: rawptr, count: int),
	on_flush_failed:       proc(user: rawptr, reason: string),
	on_feedback_submitted: proc(user: rawptr),
	on_feedback_failed:    proc(user: rawptr, reason: string),
	// EXPERIMENTAL: `suggestions_json` is a JSON array, valid only for the
	// duration of the call. ok is false when the fetch failed.
	on_suggestions:        proc(user: rawptr, suggestions_json: string, ok: bool),
	on_log:                proc(user: rawptr, message: string),
}

// Zero values mean defaults, so `Config{ingest_key = "gt_live_..."}` is a
// complete configuration.
Config :: struct {
	// Publishable ingest key, format gt_live_... Required.
	ingest_key:               string,
	// Base URL; "/api/v1" is appended when omitted. Default DEFAULT_API_URL.
	api_url:                  string,
	// Reported as the client's game version. Default "1.0.0".
	game_version:             string,
	// Reported platform. Default: the OS this build targets.
	platform:                 string,
	// Stable per-install id. Default: random per run; persist and pass it
	// back yourself if you want returning players counted as returning.
	device_id:                string,
	// Offline queue cap; oldest events are dropped first. Default 500.
	max_queue_size:           int,
	// Queued events are flushed at least this often. 0 means the 5000 ms
	// default; negative disables the timer (explicit flush() only).
	flush_interval_ms:        i64,
	// Per-request timeout. Default 15000 ms.
	request_timeout_ms:       i64,
	// Set true to suppress the automatic game_started / game_exited events.
	disable_lifecycle_events: bool,
	callbacks:                Callbacks,
}

Side_Kind :: enum {
	Feedback,
	Suggestions,
}

Transfer :: struct {
	easy:     CURL,
	kind:     Request_Kind, // protocol transfers; .None for side transfers
	is_side:  bool,
	side:     Side_Kind,
	body_buf: [dynamic]u8, // response body accumulator
	headers:  ^Curl_Slist,
	url:      cstring, // owned; must outlive the transfer
	ctx:      runtime.Context,
}

Client :: struct {
	allocator:          runtime.Allocator,
	core:               Core,
	cb:                 Callbacks,
	api_url:            string, // owned, normalized
	ingest_key:         string, // owned
	game_version:       string, // owned
	platform:           string, // owned
	device_id:          string, // owned
	request_timeout_ms: i64,
	lifecycle:          bool,
	multi:              CURLM,
	protocol:           ^Transfer, // the single in-flight protocol request
	side:               [dynamic]^Transfer,
}

@(private)
curl_global_ready := false

// Creates a client. Call tick() once per frame and shutdown() on exit.
create :: proc(config: Config, allocator := context.allocator) -> (client: ^Client, err: Error) {
	if len(strings.trim_space(config.ingest_key)) == 0 {
		return nil, .Missing_Ingest_Key
	}
	if !curl_global_ready {
		if curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK {
			return nil, .Curl_Init_Failed
		}
		curl_global_ready = true
	}
	multi := curl_multi_init()
	if multi == nil {
		return nil, .Curl_Init_Failed
	}

	context.allocator = allocator
	cl := new(Client)
	cl.allocator = allocator
	cl.multi = multi
	cl.cb = config.callbacks
	cl.api_url = normalize_api_url(config.api_url)
	cl.ingest_key = strings.clone(config.ingest_key)
	cl.game_version = strings.clone(len(config.game_version) > 0 ? config.game_version : "1.0.0")
	cl.platform = strings.clone(len(config.platform) > 0 ? config.platform : default_platform())
	cl.device_id = len(config.device_id) > 0 ? strings.clone(config.device_id) : generate_device_id(allocator)
	cl.request_timeout_ms = config.request_timeout_ms > 0 ? config.request_timeout_ms : DEFAULT_REQUEST_TIMEOUT_MS
	cl.lifecycle = !config.disable_lifecycle_events
	cl.side = make([dynamic]^Transfer)

	flush_interval := config.flush_interval_ms
	if flush_interval == 0 {
		flush_interval = DEFAULT_FLUSH_INTERVAL_MS
	}
	cl.core = core_make(config.max_queue_size, flush_interval, allocator)
	return cl, .None
}

// Queues an event. `data` is any JSON-serializable value (a struct or a map
// with string keys); nil sends an empty object. Non-blocking; returns false
// when tracking is off or `data` cannot be serialized.
track :: proc(client: ^Client, name: string, data: any = nil) -> bool {
	context.allocator = client.allocator
	data_json := ""
	if data != nil {
		bytes, merr := json.marshal(data)
		if merr != nil {
			log(client, "event data is not JSON-serializable, event not queued")
			return false
		}
		defer delete(bytes)
		return core_track(&client.core, name, string(bytes), now_ms())
	}
	return core_track(&client.core, name, data_json, now_ms())
}

// Asks for queued events to be sent on the next tick(), without waiting for
// the flush timer. With force = true any active backoff wait is skipped too.
flush :: proc(client: ^Client, force := false) {
	if force {
		core_force_flush(&client.core)
	} else {
		core_request_flush(&client.core)
	}
}

// Local opt-in and opt-out, e.g. for a privacy toggle. Disabling discards
// anything still queued.
set_enabled :: proc(client: ^Client, enabled: bool) {
	context.allocator = client.allocator
	core_set_enabled(&client.core, enabled)
}

// True once a session token has been issued and is still valid.
is_ready :: proc(client: ^Client) -> bool {
	return core_is_session_valid(&client.core, now_ms())
}

// False when the server-side kill switch or a local opt-out has tracking off.
is_active :: proc(client: ^Client) -> bool {
	return core_is_active(&client.core)
}

queue_len :: proc(client: ^Client) -> int {
	return len(client.core.queue)
}

stats :: proc(client: ^Client) -> Stats {
	return client.core.stats
}

// Submits free-form player feedback. `category` and `rating` are optional;
// pass rating in 1..5 if you have one, or leave it 0 to omit it. Failures
// arrive via on_feedback_failed. Returns false when the request could not
// even be started.
submit_feedback :: proc(client: ^Client, message: string, category := "", rating := 0) -> bool {
	context.allocator = client.allocator
	if !core_is_active(&client.core) {
		fail_feedback(client, "tracking_disabled")
		return false
	}
	if len(strings.trim_space(message)) == 0 {
		fail_feedback(client, "empty_message")
		return false
	}
	if !core_is_session_valid(&client.core, now_ms()) {
		// Ask the core to open a session so a retry can succeed.
		core_want_session(&client.core)
		fail_feedback(client, "no_session")
		return false
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"message":`)
	write_json_string(&b, message)
	if len(category) > 0 {
		strings.write_string(&b, `,"category":`)
		write_json_string(&b, category)
	}
	if rating > 0 {
		strings.write_string(&b, `,"rating":`)
		strings.write_int(&b, rating)
	}
	strings.write_byte(&b, '}')

	t := start_request(client, "/feedback", strings.to_string(b), .Session_Token)
	if t == nil {
		fail_feedback(client, "request_error")
		return false
	}
	t.is_side = true
	t.side = .Feedback
	append(&client.side, t)
	return true
}

// EXPERIMENTAL: fetches AI-generated design suggestions for this game. The
// result arrives via on_suggestions. Empty until the game has accumulated
// enough data for weekly digests; the shape may change, so do not build
// critical game logic around it.
fetch_suggestions :: proc(client: ^Client) -> bool {
	context.allocator = client.allocator
	t := start_request(client, "/agent/suggestions", "", .API_Key)
	if t == nil {
		if client.cb.on_suggestions != nil {
			client.cb.on_suggestions(client.cb.user, "[]", false)
		}
		return false
	}
	t.is_side = true
	t.side = .Suggestions
	append(&client.side, t)
	return true
}

// Pumps the SDK: progresses in-flight requests, dispatches callbacks and
// starts the next protocol request when one is due. Call once per frame;
// each call does a small, bounded amount of work and never blocks.
tick :: proc(client: ^Client) {
	context.allocator = client.allocator
	pump(client)
	start_next_protocol_request(client)
}

// Flushes remaining events (best effort, bounded by `flush_timeout_ms`,
// pass 0 to skip) and frees the client. The final automatic event is
// game_exited, mirroring the other Ravensight SDKs.
shutdown :: proc(client: ^Client, flush_timeout_ms: i64 = 2000) {
	context.allocator = client.allocator

	if client.lifecycle && core_is_active(&client.core) && client.core.settings_checked {
		track(client, "game_exited")
	}
	if flush_timeout_ms > 0 && core_is_active(&client.core) {
		core_force_flush(&client.core)
		deadline := now_ms() + flush_timeout_ms
		for now_ms() < deadline {
			tick(client)
			if len(client.core.queue) == 0 && client.protocol == nil && len(client.side) == 0 {
				break
			}
			if now_ms() < client.core.next_attempt_at_ms {
				break // backing off; do not stall the exit waiting it out
			}
			curl_multi_wait(client.multi, nil, 0, 20, nil)
		}
	}

	if client.protocol != nil {
		free_transfer(client, client.protocol)
		client.protocol = nil
	}
	for t in client.side {
		free_transfer(client, t)
	}
	delete(client.side)
	curl_multi_cleanup(client.multi)

	core_destroy(&client.core)
	delete(client.api_url)
	delete(client.ingest_key)
	delete(client.game_version)
	delete(client.platform)
	delete(client.device_id)
	free(client)
}

// --- Internals ----------------------------------------------------------------

@(private)
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private)
default_platform :: proc() -> string {
	when ODIN_OS == .Windows {
		return "windows"
	} else when ODIN_OS == .Darwin {
		return "macos"
	} else when ODIN_OS == .Linux {
		return "linux"
	} else {
		return "odin"
	}
}

@(private)
generate_device_id :: proc(allocator: runtime.Allocator) -> string {
	return fmt.aprintf("dev_%016x%016x", rand.uint64(), rand.uint64(), allocator = allocator)
}

@(private)
log :: proc(client: ^Client, message: string) {
	if client.cb.on_log != nil {
		client.cb.on_log(client.cb.user, message)
	}
}

@(private)
fail_feedback :: proc(client: ^Client, reason: string) {
	if client.cb.on_feedback_failed != nil {
		client.cb.on_feedback_failed(client.cb.user, reason)
	}
}

// How a request authenticates: the publishable ingest key or the current
// session token.
@(private)
Auth :: enum {
	API_Key,
	Session_Token,
}

write_cb :: proc "c" (ptr: [^]u8, size: c.size_t, nmemb: c.size_t, user: rawptr) -> c.size_t {
	t := (^Transfer)(user)
	context = t.ctx
	n := int(size) * int(nmemb)
	if n > 0 {
		append(&t.body_buf, ..ptr[:n])
	}
	return c.size_t(n)
}

// Starts one HTTP request through the multi handle. `body` == "" means GET.
// Returns nil when curl refuses to hand out a handle.
@(private)
start_request :: proc(client: ^Client, path: string, body: string, auth: Auth) -> ^Transfer {
	easy := curl_easy_init()
	if easy == nil {
		return nil
	}

	t := new(Transfer)
	t.easy = easy
	t.body_buf = make([dynamic]u8)
	t.ctx = context
	t.url = strings.clone_to_cstring(fmt.tprintf("%s%s", client.api_url, path))

	add_header :: proc(t: ^Transfer, header: string) {
		ch := strings.clone_to_cstring(header, context.temp_allocator)
		t.headers = curl_slist_append(t.headers, ch) // curl copies the string
	}
	if len(body) > 0 {
		add_header(t, "Content-Type: application/json")
	}
	switch auth {
	case .API_Key:
		add_header(t, fmt.tprintf("X-API-Key: %s", client.ingest_key))
	case .Session_Token:
		add_header(t, fmt.tprintf("X-Session-Token: %s", client.core.session_token))
	}

	curl_setopt_str(easy, CURLOPT_URL, t.url)
	curl_setopt_write_proc(easy, CURLOPT_WRITEFUNCTION, write_cb)
	curl_setopt_ptr(easy, CURLOPT_WRITEDATA, t)
	curl_setopt_slist(easy, CURLOPT_HTTPHEADER, t.headers)
	curl_setopt_long(easy, CURLOPT_NOSIGNAL, 1)
	curl_setopt_long(easy, CURLOPT_TIMEOUT_MS, c.long(client.request_timeout_ms))
	curl_setopt_long(easy, CURLOPT_CONNECTTIMEOUT_MS, c.long(min(client.request_timeout_ms, 10_000)))
	ua := strings.clone_to_cstring(fmt.tprintf("ravensight-odin/%s", VERSION), context.temp_allocator)
	curl_setopt_str(easy, CURLOPT_USERAGENT, ua)
	if len(body) > 0 {
		cbody := strings.clone_to_cstring(body, context.temp_allocator)
		curl_setopt_str(easy, CURLOPT_COPYPOSTFIELDS, cbody) // curl copies the body
	} else {
		curl_setopt_long(easy, CURLOPT_HTTPGET, 1)
	}

	if curl_multi_add_handle(client.multi, easy) != 0 {
		free_transfer(client, t, remove_from_multi = false)
		return nil
	}
	return t
}

@(private)
free_transfer :: proc(client: ^Client, t: ^Transfer, remove_from_multi := true) {
	if remove_from_multi {
		curl_multi_remove_handle(client.multi, t.easy)
	}
	curl_easy_cleanup(t.easy)
	if t.headers != nil {
		curl_slist_free_all(t.headers)
	}
	delete(t.body_buf)
	delete(t.url)
	free(t)
}

@(private)
start_next_protocol_request :: proc(client: ^Client) {
	if client.protocol != nil {
		return
	}
	req, ok := core_next(&client.core, now_ms())
	if !ok {
		return
	}

	t: ^Transfer
	switch req.kind {
	case .Settings:
		t = start_request(client, "/settings", "", .API_Key)
	case .Session:
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"deviceId":`)
		write_json_string(&b, client.device_id)
		strings.write_string(&b, `,"gameVersion":`)
		write_json_string(&b, client.game_version)
		strings.write_string(&b, `,"platform":`)
		write_json_string(&b, client.platform)
		strings.write_byte(&b, '}')
		t = start_request(client, "/session", strings.to_string(b), .API_Key)
	case .Batch:
		t = start_request(client, "/track/batch", req.body, .Session_Token)
		delete(req.body)
	case .None:
	}

	if t == nil {
		// Could not even start the request; report it as a transport
		// failure so the core schedules a retry.
		sig := core_on_response(&client.core, Core_Response{status = 0, error_code = "request_error"}, now_ms())
		dispatch(client, sig)
		return
	}
	t.kind = req.kind
	client.protocol = t
}

@(private)
pump :: proc(client: ^Client) {
	running: c.int
	curl_multi_perform(client.multi, &running)

	for {
		msgs: c.int
		msg := curl_multi_info_read(client.multi, &msgs)
		if msg == nil {
			break
		}
		if msg.msg != CURLMSG_DONE {
			continue
		}
		on_transfer_done(client, msg.easy_handle, msg.data.result)
	}
}

@(private)
on_transfer_done :: proc(client: ^Client, easy: CURL, curl_result: c.int) {
	status := 0
	retry_after_ms: i64
	if curl_result == CURLE_OK {
		code: c.long
		if curl_getinfo_long(easy, CURLINFO_RESPONSE_CODE, &code) == CURLE_OK {
			status = int(code)
		}
		retry_after_s: i64
		if curl_getinfo_off_t(easy, CURLINFO_RETRY_AFTER, &retry_after_s) == CURLE_OK {
			retry_after_ms = retry_after_s * 1000
		}
	}

	if client.protocol != nil && client.protocol.easy == easy {
		t := client.protocol
		client.protocol = nil
		handle_protocol_response(client, t, status, retry_after_ms)
		free_transfer(client, t)
		return
	}
	for st, i in client.side {
		if st.easy == easy {
			unordered_remove(&client.side, i)
			handle_side_response(client, st, status)
			free_transfer(client, st)
			return
		}
	}
}

@(private)
handle_protocol_response :: proc(client: ^Client, t: ^Transfer, status: int, retry_after_ms: i64) {
	res := Core_Response{
		status         = status,
		retry_after_ms = retry_after_ms,
	}

	parsed, ok := parse_body(t.body_buf[:])
	defer if ok {json.destroy_value(parsed)}
	obj, is_obj := parsed.(json.Object)

	fallback_buf: [32]u8
	if is_obj {
		if e, has := obj["error"]; has {
			if s, is_str := e.(json.String); is_str {
				res.error_code = string(s)
			}
		}
	}
	if len(res.error_code) == 0 && status != 0 {
		res.error_code = fmt.bprintf(fallback_buf[:], "http_%d", status)
	}

	was_settings := t.kind == .Settings

	switch t.kind {
	case .Settings:
		if is_obj {
			if v, has := obj["trackingEnabled"]; has {
				if b, is_bool := v.(json.Boolean); is_bool {
					res.has_tracking_enabled = true
					res.tracking_enabled = bool(b)
				}
			}
		}
		if status != 200 {
			log(client, "settings check failed, assuming tracking enabled")
		}
	case .Session:
		if is_obj {
			if v, has := obj["token"]; has {
				if s, is_str := v.(json.String); is_str {
					res.token = string(s)
				}
			}
			if v, has := obj["expiresAt"]; has {
				res.expires_at_ms = json_number_i64(v) * 1000
			}
			if v, has := obj["expiresIn"]; has {
				res.expires_in_ms = json_number_i64(v) * 1000
			}
		}
	case .Batch, .None:
	}

	sig := core_on_response(&client.core, res, now_ms())
	dispatch(client, sig)

	// Mirror the Godot autoload: once the kill switch has been read and
	// tracking is on, the first automatic event is game_started (which also
	// kicks off session creation).
	if was_settings && client.lifecycle && core_is_active(&client.core) {
		track(client, "game_started")
	}
}

@(private)
handle_side_response :: proc(client: ^Client, t: ^Transfer, status: int) {
	switch t.side {
	case .Feedback:
		if status == 201 {
			if client.cb.on_feedback_submitted != nil {
				client.cb.on_feedback_submitted(client.cb.user)
			}
			return
		}
		reason_buf: [32]u8
		reason := status != 0 ? fmt.bprintf(reason_buf[:], "http_%d", status) : "network_error"
		parsed, ok := parse_body(t.body_buf[:])
		defer if ok {json.destroy_value(parsed)}
		if obj, is_obj := parsed.(json.Object); is_obj {
			if e, has := obj["error"]; has {
				if s, is_str := e.(json.String); is_str {
					reason = string(s)
				}
			}
		}
		fail_feedback(client, reason)
	case .Suggestions:
		if client.cb.on_suggestions == nil {
			return
		}
		if status == 200 {
			parsed, ok := parse_body(t.body_buf[:])
			defer if ok {json.destroy_value(parsed)}
			if obj, is_obj := parsed.(json.Object); is_obj {
				if v, has := obj["suggestions"]; has {
					if _, is_arr := v.(json.Array); is_arr {
						text, uerr := json.unparse(v, allocator = context.temp_allocator)
						if uerr == nil {
							client.cb.on_suggestions(client.cb.user, text, true)
							return
						}
					}
				}
			}
			client.cb.on_suggestions(client.cb.user, "[]", true)
			return
		}
		client.cb.on_suggestions(client.cb.user, "[]", false)
	}
}

@(private)
dispatch :: proc(client: ^Client, sig: Signals) {
	if sig.session_ready && client.cb.on_session_ready != nil {
		client.cb.on_session_ready(client.cb.user)
	}
	if sig.session_failed && client.cb.on_session_failed != nil {
		client.cb.on_session_failed(client.cb.user, sig.reason)
	}
	if sig.tracking_disabled {
		log(client, "tracking disabled by server kill switch")
		if client.cb.on_tracking_disabled != nil {
			client.cb.on_tracking_disabled(client.cb.user)
		}
	}
	if sig.events_flushed > 0 && client.cb.on_events_flushed != nil {
		client.cb.on_events_flushed(client.cb.user, sig.events_flushed)
	}
	if sig.flush_failed && client.cb.on_flush_failed != nil {
		client.cb.on_flush_failed(client.cb.user, sig.reason)
	}
	if sig.event_dropped {
		log(client, "dropped one event rejected with HTTP 400")
	}
}

@(private)
parse_body :: proc(body: []u8) -> (val: json.Value, ok: bool) {
	if len(body) == 0 {
		return nil, false
	}
	parsed, err := json.parse(body, parse_integers = true)
	if err != nil {
		return nil, false
	}
	return parsed, true
}

@(private)
json_number_i64 :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer:
		return i64(n)
	case json.Float:
		return i64(n)
	}
	return 0
}
