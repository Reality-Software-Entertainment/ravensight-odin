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
import "core:os"
import "core:strings"
import "core:time"

VERSION :: "0.3.0"
DEFAULT_API_URL :: "https://api.ravensight.io"
DEFAULT_REQUEST_TIMEOUT_MS :: 15_000
// shutdown() holds the quit for at most this long by default.
QUIT_FLUSH_TIMEOUT_MS :: 1_500
// Feedback submitted before a session exists waits for one, up to this many.
MAX_PENDING_FEEDBACK :: 5

// The categories POST /feedback accepts. Anything else fails locally with
// "invalid_category" and no request is made.
FEEDBACK_CATEGORIES :: [6]string{"bug", "suggestion", "complaint", "praise", "playtest", "other"}

INVALID_KEY_WARNING :: "Ravensight: ingest key refused (invalid_key), sending stopped for this run. Check your gt_live_ key."
NO_KEY_WARNING :: "Ravensight: no ingest_key, so analytics is off for this run (set Config.optional to silence this line)."
// The distribution label is at most this many characters, counted in UTF-16
// units as the server counts them.
MAX_DISTRIBUTION_LENGTH :: 40

Error :: enum {
	None,
	// No longer returned since 0.3.0: an empty key makes an inert client.
	Missing_Ingest_Key,
	Curl_Init_Failed,
}

// When the client may start collecting.
Consent :: enum {
	// The default: collecting until the player opts out with
	// set_tracking_enabled(client, false), which is saved.
	Opt_Out,
	// Nothing at all until the player's set_tracking_enabled(client, true):
	// no device id, no settings check, no session. Events tracked before the
	// yes are dropped. The yes is saved in the storage file.
	Opt_In,
}

Log_Level :: enum {
	Info,
	Warning,
}

// All callbacks are optional and are invoked from inside tick() (or the
// call that caused them), on the calling thread. `user` is passed through
// untouched.
Callbacks :: struct {
	user:                  rawptr,
	on_session_ready:      proc(user: rawptr),
	// `reason` is one of the Reason strings, e.g. "invalid_key", "offline".
	on_session_failed:     proc(user: rawptr, reason: string),
	on_tracking_disabled:  proc(user: rawptr),
	on_events_flushed:     proc(user: rawptr, count: int),
	// Also called with "event_too_large" for an event whose data is over
	// MAX_EVENT_BYTES as JSON, which is dropped before it is queued.
	on_flush_failed:       proc(user: rawptr, reason: string),
	on_feedback_submitted: proc(user: rawptr),
	on_feedback_failed:    proc(user: rawptr, reason: string),
	// EXPERIMENTAL: `suggestions_json` is a JSON array, valid only for the
	// duration of the call. ok is false when the fetch failed or was not
	// made because the client is not active.
	on_suggestions:        proc(user: rawptr, suggestions_json: string, ok: bool),
	// Called whenever init_reason(client) changes.
	on_reason_changed:     proc(user: rawptr, reason: Reason),
	// Every message starts with "Ravensight: ". Without a handler, warnings
	// are printed to stderr and info lines are discarded.
	on_log:                proc(user: rawptr, level: Log_Level, message: string),
}

// Zero values mean defaults, so `Config{ingest_key = "gt_live_..."}` is a
// complete configuration.
Config :: struct {
	// Publishable ingest key, gt_live_... or, for a build anyone can
	// download, a public gt_pub_... key injected at build time. Empty makes
	// the client inert: no files, no requests, libcurl never initialized,
	// every call a quiet no-op, init_reason .No_Key.
	ingest_key:               string,
	// True silences the one warning an inert client (no key) logs.
	optional:                 bool,
	// .Opt_In sends nothing, and makes no device id, until the player's
	// set_tracking_enabled(client, true). The zero value .Opt_Out keeps the
	// 0.2.0 behaviour.
	consent:                  Consent,
	// A short label of your own for this build, such as "native-release" or
	// "itch-demo", sent on POST /session as distribution. Trimmed; at most
	// 40 characters, no control characters, otherwise not sent (one
	// warning). "" sends nothing.
	distribution:             string,
	// API host. With or without "/api/v1" and trailing slashes. Default
	// "https://api.ravensight.io".
	api_url:                  string,
	// Reported as the client's game version. Default "1.0.0".
	game_version:             string,
	// Reported platform. Default: the OS this build targets.
	platform:                 string,
	// Overrides the saved device id for this run. Default: the id saved in
	// the storage file, created on first launch.
	device_id:                string,
	// Where the device id and the player's opt-out are saved. Default
	// default_storage_path().
	storage_path:             string,
	// Start with sending off until set_enabled(client, true). Not saved.
	start_disabled:           bool,
	// Offline queue cap; oldest events are dropped first. Default 500.
	max_queue_size:           int,
	// Queued events are flushed at least this often. 0 means the 5000 ms
	// default; negative disables the timer (explicit flush() only).
	flush_interval_ms:        i64,
	// Per-request timeout. Default 15000 ms.
	request_timeout_ms:       i64,
	// Set true to suppress the automatic game_started / game_exited events.
	disable_lifecycle_events: bool,
	// Ravensight Playtest. Normally left empty: the playtest runner passes
	// these through RAVENSIGHT_PLAYTEST_* variables or command line
	// arguments. A value here wins over both.
	playtest_token:           string,
	playtest_run_id:          string,
	playtest_job_id:          string,
	playtest_persona:         string,
	callbacks:                Callbacks,
}

Side_Kind :: enum {
	Feedback,
	Suggestions,
}

Transfer :: struct {
	easy:     CURL, // nil when a test transport carries the request
	kind:     Request_Kind, // protocol transfers; .None for side transfers
	is_side:  bool,
	side:     Side_Kind,
	body_buf: [dynamic]u8, // response body accumulator
	headers:  ^Curl_Slist,
	url:      cstring, // owned; must outlive the transfer
	ctx:      runtime.Context,
	feedback: Pending_Feedback, // feedback transfers keep their body for one re-send
}

@(private)
Pending_Feedback :: struct {
	body:    string, // owned
	retried: bool,
}

// One HTTP request as handed to a transport. Everything is borrowed for the
// duration of the call. `body` "" means GET.
Http_Request :: struct {
	url:     string,
	headers: []string,
	body:    string,
}

// The seam between the client and the network. The zero value means
// libcurl and the wall clock; tests install a fake that records requests
// and answers them through finish_transfer().
@(private)
Transport :: struct {
	user: rawptr,
	send: proc(user: rawptr, t: ^Transfer, req: Http_Request) -> bool,
	now:  proc(user: rawptr) -> i64,
	// Called while shutdown() waits for its final flush.
	idle: proc(user: rawptr),
}

Client :: struct {
	allocator:          runtime.Allocator,
	core:               Core,
	cb:                 Callbacks,
	api_url:            string, // owned, normalized
	ingest_key:         string, // owned
	game_version:       string, // owned
	platform:           string, // owned
	device_id:          string, // owned; the id sent this run
	saved_device_id:    string, // owned; the id in the storage file, may be ""
	storage_path:       string, // owned; "" in a playtest run or without storage
	consent:            Consent,
	saved_opt_in:       bool, // the yes saved for Consent.Opt_In
	distribution:       string, // owned; validated, "" when unset or invalid
	event_nonce:        string, // owned; 8 hex characters, once per client
	event_counter:      u64,
	start_unix_s:       i64,
	warned_too_large:   bool,
	playtest:           Playtest_Context, // owned strings; token "" outside a playtest
	request_timeout_ms: i64,
	lifecycle:          bool,
	started_queued:     bool, // once-guard for game_started
	exited_queued:      bool, // once-guard for game_exited
	pending_feedback:   [dynamic]Pending_Feedback,
	last_reason:        Reason,
	warned_key:         bool,
	warned_stop:        bool,
	warned_kill:        bool,
	warned_drop:        bool,
	transport:          Transport,
	multi:              CURLM,
	protocol:           ^Transfer, // the single in-flight protocol request
	side:               [dynamic]^Transfer,
}

@(private)
curl_global_ready := false

// Creates a client. Call tick() once per frame and shutdown() on exit.
// Reads the saved device id and the player's opt-out synchronously, and
// queues game_started with this moment's timestamp when tracking is on.
create :: proc(config: Config, allocator := context.allocator) -> (client: ^Client, err: Error) {
	return create_with_transport(config, Transport{}, true, allocator)
}

@(private)
create_with_transport :: proc(config: Config, transport: Transport, read_process: bool, allocator := context.allocator) -> (client: ^Client, err: Error) {
	if len(strings.trim_space(config.ingest_key)) == 0 {
		return create_inert(config, transport, allocator), .None
	}
	multi: CURLM
	if transport.send == nil {
		if !curl_global_ready {
			if curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK {
				return nil, .Curl_Init_Failed
			}
			curl_global_ready = true
		}
		multi = curl_multi_init()
		if multi == nil {
			return nil, .Curl_Init_Failed
		}
	}

	context.allocator = allocator
	cl := new(Client)
	cl.allocator = allocator
	cl.transport = transport
	cl.multi = multi
	cl.cb = config.callbacks
	cl.api_url = normalize_api_url(config.api_url)
	cl.ingest_key = strings.clone(strings.trim_space(config.ingest_key))
	cl.game_version = strings.clone(len(config.game_version) > 0 ? config.game_version : "1.0.0")
	cl.platform = strings.clone(len(config.platform) > 0 ? config.platform : default_platform())
	cl.request_timeout_ms = config.request_timeout_ms > 0 ? config.request_timeout_ms : DEFAULT_REQUEST_TIMEOUT_MS
	cl.lifecycle = !config.disable_lifecycle_events
	cl.side = make([dynamic]^Transfer)
	cl.pending_feedback = make([dynamic]Pending_Feedback)

	flush_interval := config.flush_interval_ms
	if flush_interval == 0 {
		flush_interval = DEFAULT_FLUSH_INTERVAL_MS
	}
	cl.core = core_make(config.max_queue_size, flush_interval, allocator)
	cl.core.enabled = !config.start_disabled
	cl.core.random = random_unit
	cl.consent = config.consent
	cl.event_nonce = random_hex(4, allocator)
	cl.start_unix_s = client_now(cl) / 1000
	label, bad_label := validated_distribution(config.distribution)
	cl.distribution = strings.clone(label)
	if bad_label {
		log(cl, .Warning, "Ravensight: distribution must be at most 40 characters with no control characters; it is not sent.")
	}

	explicit := Playtest_Context{
		token   = config.playtest_token,
		run_id  = config.playtest_run_id,
		job_id  = config.playtest_job_id,
		persona = config.playtest_persona,
	}
	env: Playtest_Context
	args: []string
	if read_process {
		env = read_playtest_env(context.temp_allocator)
		args = os.args
	}
	pt := resolve_playtest(explicit, env, args)

	if len(pt.token) > 0 {
		// A playtest run: an in-memory pt-<runId> identity, the saved file
		// is never read or written, the saved opt-out does not apply.
		cl.playtest = Playtest_Context{
			token   = strings.clone(pt.token),
			run_id  = strings.clone(pt.run_id),
			job_id  = strings.clone(pt.job_id),
			persona = strings.clone(pt.persona),
		}
		cl.saved_device_id = ""
		cl.storage_path = ""
		if len(pt.run_id) == 0 {
			// Never run a playtest build as a real player.
			cl.device_id = strings.clone("")
			core_stop(&cl.core, .Session_Failed)
			cl.warned_stop = true
			log(cl, .Warning, "Ravensight: playtest token without a run id (session_failed), sending stopped for this run.")
		} else {
			cl.device_id = strings.concatenate({"pt-", pt.run_id})
		}
	} else {
		cl.storage_path = len(config.storage_path) > 0 ? strings.clone(config.storage_path) : default_storage_path()
		saved := load_identity(cl.storage_path)
		cl.saved_opt_in = saved.opted_in
		cl.core.opted_out = !saved_choice(saved, cl.consent)
		if saved.unreadable {
			// It may hold an opt-out: honour that for this run, keep the
			// file, and use an id that is never saved. Only the player's own
			// set_tracking_enabled or reset_device_id replaces the file.
			cl.core.opted_out = true
			cl.saved_device_id = generate_device_id(allocator)
			log(cl, .Warning, "Ravensight: the storage file exists but could not be read; tracking is off for this run and the file was left as it is.")
		} else if len(saved.device_id) > 0 {
			cl.saved_device_id = saved.device_id
		} else if cl.consent == .Opt_In && cl.core.opted_out {
			// No yes yet: no device id is made or saved until there is one.
			cl.saved_device_id = strings.clone("")
		} else {
			cl.saved_device_id = generate_device_id(allocator)
			if !save_identity(cl.storage_path, Saved_Identity{device_id = cl.saved_device_id, tracking_enabled = saved.tracking_enabled, opted_in = saved.opted_in}) {
				log(cl, .Warning, "Ravensight: could not save the device id; players will count as new each launch. Set Config.storage_path to a writable file.")
			}
		}
		override := strings.trim_space(config.device_id)
		cl.device_id = strings.clone(len(override) > 0 ? override : cl.saved_device_id)
	}

	maybe_queue_game_started(cl)
	cl.last_reason = core_reason(&cl.core)
	return cl, .None
}

// A keyless clone or a development build: a client that is never active.
// No libcurl, no file written, no request; the storage path is kept only so
// the player's choice can still be saved.
@(private)
create_inert :: proc(config: Config, transport: Transport, allocator: runtime.Allocator) -> ^Client {
	context.allocator = allocator
	cl := new(Client)
	cl.allocator = allocator
	cl.transport = transport
	cl.cb = config.callbacks
	cl.api_url = normalize_api_url(config.api_url)
	cl.ingest_key = strings.clone("")
	cl.game_version = strings.clone(len(config.game_version) > 0 ? config.game_version : "1.0.0")
	cl.platform = strings.clone(len(config.platform) > 0 ? config.platform : default_platform())
	cl.side = make([dynamic]^Transfer)
	cl.pending_feedback = make([dynamic]Pending_Feedback)
	cl.core = core_make(config.max_queue_size, DEFAULT_FLUSH_INTERVAL_MS, allocator)
	cl.core.inert = true
	cl.consent = config.consent
	cl.storage_path = len(config.storage_path) > 0 ? strings.clone(config.storage_path) : default_storage_path()
	saved := load_identity(cl.storage_path)
	cl.saved_opt_in = saved.opted_in
	cl.core.opted_out = !saved_choice(saved, cl.consent)
	cl.saved_device_id = saved.device_id
	cl.device_id = strings.clone(saved.device_id)
	cl.distribution = strings.clone("")
	cl.event_nonce = strings.clone("")
	cl.last_reason = core_reason(&cl.core)
	if !config.optional {
		log(cl, .Warning, NO_KEY_WARNING)
	}
	return cl
}

// The distribution option, trimmed, when it is valid; "" otherwise, with
// `invalid` set when there was something that could not be sent.
@(private)
validated_distribution :: proc(raw: string) -> (label: string, invalid: bool) {
	label = strings.trim_space(raw)
	if len(label) == 0 {
		return "", false
	}
	units := 0
	for i in 0 ..< len(label) {
		ch := label[i]
		if ch < 0x20 || ch == 0x7f {
			return "", true
		}
		if ch & 0xC0 != 0x80 {
			units += ch >= 0xF0 ? 2 : 1
		}
	}
	if units > MAX_DISTRIBUTION_LENGTH {
		return "", true
	}
	return label, false
}

// The next rs_event_id: the first 16 characters of the device id (anything
// outside A-Z, a-z, 0-9, _ and - replaced with _), the start time in hex,
// the per-client nonce and a counter. Allocated in the temp allocator.
@(private)
next_event_id :: proc(client: ^Client) -> string {
	client.event_counter += 1
	prefix := client.device_id[:min(16, len(client.device_id))]
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(prefix) {
		ch := prefix[i]
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
			strings.write_byte(&b, ch)
		case:
			strings.write_byte(&b, '_')
		}
	}
	fmt.sbprintf(&b, "-%x-%s-%d", client.start_unix_s, client.event_nonce, client.event_counter)
	return strings.to_string(b)
}

// Adds rs_event_id to an event's JSON object. Non-object data is left alone.
@(private)
with_event_id :: proc(client: ^Client, data_json: string) -> string {
	body := strings.trim_space(data_json)
	if len(body) == 0 {
		body = "{}"
	}
	if !strings.has_prefix(body, "{") || !strings.has_suffix(body, "}") {
		return data_json
	}
	inner := strings.trim_space(body[1:len(body) - 1])
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	if len(inner) > 0 {
		strings.write_string(&b, inner)
		strings.write_byte(&b, ',')
	}
	strings.write_string(&b, `"rs_event_id":`)
	write_json_string(&b, next_event_id(client))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// Queues an event. `data` is any JSON-serializable value (a struct or a map
// with string keys); nil sends an empty object. Only enqueues: sending
// happens from tick(). Every event's data gets an rs_event_id, kept in the
// queue so a resend carries the same id. Returns false when tracking is off,
// `data` cannot be serialized, or its JSON is over MAX_EVENT_BYTES (dropped,
// on_flush_failed "event_too_large", one warning for the run).
track :: proc(client: ^Client, name: string, data: any = nil) -> bool {
	if client == nil {
		return false
	}
	context.allocator = client.allocator
	if !core_is_active(&client.core) {
		return false
	}
	data_json := ""
	if data != nil {
		bytes, merr := json.marshal(data, allocator = context.temp_allocator)
		if merr != nil {
			log(client, .Warning, "Ravensight: event data is not JSON-serializable, event not queued.")
			return false
		}
		data_json = string(bytes)
	}
	if len(client.playtest.token) > 0 {
		data_json = with_playtest_tags(client, data_json)
	}
	if len(name) == 0 {
		return false
	}
	data_json = with_event_id(client, data_json)
	if len(data_json) > MAX_EVENT_BYTES {
		client.core.stats.dropped += 1
		if !client.warned_too_large {
			client.warned_too_large = true
			log(client, .Warning, fmt.tprintf("Ravensight: dropped event \"%s\": larger than %d bytes as JSON (further drops are not logged).", name, MAX_EVENT_BYTES))
		}
		if client.cb.on_flush_failed != nil {
			client.cb.on_flush_failed(client.cb.user, "event_too_large")
		}
		return false
	}
	return core_track(&client.core, name, data_json, client_now(client))
}

// Asks for queued events to be sent on the next tick(), without waiting for
// the flush timer. With force = true any active backoff wait is skipped too.
flush :: proc(client: ^Client, force := false) {
	if client == nil {
		return
	}
	if force {
		core_force_flush(&client.core)
	} else {
		core_request_flush(&client.core)
	}
}

// The runtime switch, the same thing as Config.start_disabled. Not saved:
// for the player's own choice use set_tracking_enabled. Disabling discards
// anything still queued.
set_enabled :: proc(client: ^Client, enabled: bool) {
	if client == nil {
		return
	}
	context.allocator = client.allocator
	core_set_enabled(&client.core, enabled)
	if enabled {
		maybe_queue_game_started(client)
	} else {
		drop_pending_feedback(client, "disabled")
	}
	sync_reason(client)
}

// The player's analytics choice, saved to the storage file synchronously and
// read again on every launch. A saved opt-out wins over Config. Turning it
// off discards the queue and stops sending. Works on a client created with
// start_disabled too. Before a client exists use write_tracking_enabled.
// With Consent.Opt_In, true is the yes that starts everything (the first
// moment a device id exists) and events tracked right after it are queued
// while the settings check runs; false again keeps the device id
// (reset_device_id forgets it). The choice is saved on an inert client and
// after a refused key too, but nothing restarts this run.
// Ignored (one log line) during a playtest run.
set_tracking_enabled :: proc(client: ^Client, enabled: bool) {
	if client == nil {
		return
	}
	context.allocator = client.allocator
	if len(client.playtest.token) > 0 {
		log(client, .Info, "Ravensight: set_tracking_enabled is ignored during a playtest run.")
		return
	}
	if enabled && !client.core.inert && !client.core.stopped && len(client.saved_device_id) == 0 {
		// Consent.Opt_In: the yes is the first moment an id may exist.
		delete(client.saved_device_id)
		delete(client.device_id)
		client.saved_device_id = generate_device_id(client.allocator)
		client.device_id = strings.clone(client.saved_device_id)
	}
	if client.consent == .Opt_In || !enabled {
		client.saved_opt_in = enabled
	}
	if !save_identity(client.storage_path, Saved_Identity{device_id = client.saved_device_id, tracking_enabled = enabled, opted_in = client.saved_opt_in}) {
		log(client, .Warning, "Ravensight: could not save the analytics choice to the storage file.")
	}
	core_set_opted_out(&client.core, !enabled)
	if enabled {
		maybe_queue_game_started(client)
	} else {
		drop_pending_feedback(client, "disabled")
	}
	sync_reason(client)
}

// False after set_tracking_enabled(client, false), on this run or a past one.
is_tracking_enabled :: proc(client: ^Client) -> bool {
	if client == nil {
		return false
	}
	return !client.core.opted_out
}

// Mints and saves a new random device id, discards the queue and drops the
// session, so nothing links what comes next to what came before. Returns
// the new id (owned by the client, valid until the next reset or shutdown).
// Ignored (one log line) during a playtest run, returning the run's id.
reset_device_id :: proc(client: ^Client) -> string {
	if client == nil {
		return ""
	}
	context.allocator = client.allocator
	if len(client.playtest.token) > 0 {
		log(client, .Info, "Ravensight: reset_device_id is ignored during a playtest run.")
		return client.device_id
	}
	if client.core.inert {
		return client.device_id
	}
	if client.consent == .Opt_In && client.core.opted_out {
		// Not opted in: forget any saved id and make none until the yes.
		if len(client.storage_path) > 0 && os.exists(client.storage_path) {
			os.remove(client.storage_path)
		}
		delete(client.saved_device_id)
		delete(client.device_id)
		client.saved_device_id = strings.clone("")
		client.device_id = strings.clone("")
		client.saved_opt_in = false
		core_discard_queue(&client.core)
		core_invalidate_session(&client.core)
		drop_pending_feedback(client, "device_id_reset")
		sync_reason(client)
		return client.device_id
	}
	fresh := generate_device_id(client.allocator)
	delete(client.saved_device_id)
	delete(client.device_id)
	client.saved_device_id = fresh
	client.device_id = strings.clone(fresh)
	if !save_identity(client.storage_path, Saved_Identity{device_id = fresh, tracking_enabled = !client.core.opted_out, opted_in = client.saved_opt_in}) {
		log(client, .Warning, "Ravensight: could not save the new device id to the storage file.")
	}
	core_discard_queue(&client.core)
	core_invalidate_session(&client.core)
	drop_pending_feedback(client, "device_id_reset")
	sync_reason(client)
	return client.device_id
}

// The device id this run sends: the saved id, Config.device_id, or
// pt-<runId> in a playtest run.
device_id :: proc(client: ^Client) -> string {
	if client == nil {
		return ""
	}
	return client.device_id
}

// True once a session token has been issued and is still valid.
is_ready :: proc(client: ^Client) -> bool {
	if client == nil {
		return false
	}
	return core_is_session_valid(&client.core, client_now(client))
}

// True when events are being queued and sent: a key, enabled, not opted out
// (or opted in), the server kill switch on, and not stopped.
is_active :: proc(client: ^Client) -> bool {
	if client == nil {
		return false
	}
	return core_is_active(&client.core)
}

// True only while the client is collecting; the same answer as is_active.
// Use it to skip work that only feeds analytics.
is_enabled :: proc(client: ^Client) -> bool {
	return is_active(client)
}

// True when a Ravensight Playtest token was found at create().
is_playtest :: proc(client: ^Client) -> bool {
	return client != nil && len(client.playtest.token) > 0
}

// Why the client is not sending, or .None. reason_string() gives the wire
// form ("invalid_key", ...). on_reason_changed reports every change.
init_reason :: proc(client: ^Client) -> Reason {
	if client == nil {
		return .Disabled
	}
	return core_reason(&client.core)
}

// The current session token, "" until a session opens (or once it expired).
// A game server can pass it as joinToken. Valid until the next tick().
session_token :: proc(client: ^Client) -> string {
	if client == nil || !core_is_session_valid(&client.core, client_now(client)) {
		return ""
	}
	return client.core.session_token
}

queue_len :: proc(client: ^Client) -> int {
	if client == nil {
		return 0
	}
	return len(client.core.queue)
}

stats :: proc(client: ^Client) -> Stats {
	if client == nil {
		return {}
	}
	return client.core.stats
}

// True when `category` is "" (omitted) or one of FEEDBACK_CATEGORIES.
is_feedback_category :: proc(category: string) -> bool {
	if len(category) == 0 {
		return true
	}
	for known in FEEDBACK_CATEGORIES {
		if category == known {
			return true
		}
	}
	return false
}

// Submits free-form player feedback. `category` is "" or one of
// FEEDBACK_CATEGORIES; `rating` is 0 (omitted) or 1 to 5. Bad input fails
// locally through on_feedback_failed ("invalid_category", "invalid_rating",
// "empty_message", "disabled") and no request is made. Feedback sent before
// a session exists waits for one (up to MAX_PENDING_FEEDBACK). Returns true
// when the feedback was sent or is waiting for the session.
submit_feedback :: proc(client: ^Client, message: string, category := "", rating := 0) -> bool {
	if client == nil {
		return false
	}
	context.allocator = client.allocator
	if !core_is_active(&client.core) {
		fail_feedback(client, client.core.inert ? "no_key" : "disabled")
		return false
	}
	if len(strings.trim_space(message)) == 0 {
		fail_feedback(client, "empty_message")
		return false
	}
	if !is_feedback_category(category) {
		fail_feedback(client, "invalid_category")
		return false
	}
	if rating != 0 && (rating < 1 || rating > 5) {
		fail_feedback(client, "invalid_rating")
		return false
	}

	b := strings.builder_make()
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
	fb := Pending_Feedback{body = strings.to_string(b)}

	if core_is_session_valid(&client.core, client_now(client)) && !client.core.key_refused {
		return send_feedback(client, fb)
	}
	if len(client.pending_feedback) >= MAX_PENDING_FEEDBACK {
		delete(fb.body)
		fail_feedback(client, "queue_full")
		return false
	}
	append(&client.pending_feedback, fb)
	core_want_session(&client.core)
	return true
}

// EXPERIMENTAL: fetches AI-generated design suggestions for this game. The
// result arrives via on_suggestions. Empty until the game has accumulated
// enough data for weekly digests; the shape may change, so do not build
// critical game logic around it. While the client is not active no request
// is made and on_suggestions gets "[]" with ok = false at once.
fetch_suggestions :: proc(client: ^Client) -> bool {
	if client == nil {
		return false
	}
	context.allocator = client.allocator
	if !core_is_active(&client.core) {
		if client.cb.on_suggestions != nil {
			client.cb.on_suggestions(client.cb.user, "[]", false)
		}
		return false
	}
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
	if client == nil {
		return
	}
	context.allocator = client.allocator
	pump(client)
	start_next_protocol_request(client)
	sync_reason(client)
}

// The quit path: queues game_exited (once), makes one best-effort flush that
// holds the quit for at most `flush_timeout_ms` (default 1500, 0 skips it),
// then frees the client. Anything not delivered by then is gone.
shutdown :: proc(client: ^Client, flush_timeout_ms: i64 = QUIT_FLUSH_TIMEOUT_MS) {
	if client == nil {
		return
	}
	context.allocator = client.allocator

	if client.lifecycle && !client.exited_queued && core_is_active(&client.core) {
		client.exited_queued = true
		track(client, "game_exited")
	}
	has_work := len(client.core.queue) > 0 || len(client.pending_feedback) > 0 || len(client.side) > 0
	if flush_timeout_ms > 0 && has_work && core_is_active(&client.core) && !client.core.key_refused {
		core_force_flush(&client.core)
		deadline := client_now(client) + flush_timeout_ms
		for client_now(client) < deadline {
			tick(client)
			idle := len(client.core.queue) == 0 && len(client.pending_feedback) == 0
			if idle && client.protocol == nil && len(client.side) == 0 {
				break
			}
			if !core_is_active(&client.core) || client.core.key_refused {
				break
			}
			if client.protocol == nil && client_now(client) < client.core.next_attempt_at_ms {
				break // backing off; do not stall the exit waiting it out
			}
			wait_for_network(client)
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
	for fb in client.pending_feedback {
		delete(fb.body)
	}
	delete(client.pending_feedback)
	if client.multi != nil {
		curl_multi_cleanup(client.multi)
	}

	core_destroy(&client.core)
	delete(client.api_url)
	delete(client.ingest_key)
	delete(client.game_version)
	delete(client.platform)
	delete(client.device_id)
	delete(client.saved_device_id)
	delete(client.storage_path)
	delete(client.distribution)
	delete(client.event_nonce)
	delete(client.playtest.token)
	delete(client.playtest.run_id)
	delete(client.playtest.job_id)
	delete(client.playtest.persona)
	free(client)
}

// --- Internals ----------------------------------------------------------------

@(private)
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private)
client_now :: proc(client: ^Client) -> i64 {
	if client.transport.now != nil {
		return client.transport.now(client.transport.user)
	}
	return now_ms()
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
log :: proc(client: ^Client, level: Log_Level, message: string) {
	if client.cb.on_log != nil {
		client.cb.on_log(client.cb.user, level, message)
	} else if level == .Warning {
		fmt.eprintln(message)
	}
}

@(private)
fail_feedback :: proc(client: ^Client, reason: string) {
	if client.cb.on_feedback_failed != nil {
		client.cb.on_feedback_failed(client.cb.user, reason)
	}
}

// Queues game_started once per run, the first time the client is active.
@(private)
maybe_queue_game_started :: proc(client: ^Client) {
	if !client.lifecycle || client.started_queued || !core_is_active(&client.core) {
		return
	}
	if track(client, "game_started") {
		client.started_queued = true
	}
}

@(private)
sync_reason :: proc(client: ^Client) {
	r := core_reason(&client.core)
	if r == client.last_reason {
		return
	}
	client.last_reason = r
	if client.cb.on_reason_changed != nil {
		client.cb.on_reason_changed(client.cb.user, r)
	}
}

// Merges the playtest tags into an event's JSON object (tags win on a
// clash, as the last duplicate key). Non-object data is left alone.
@(private)
with_playtest_tags :: proc(client: ^Client, data_json: string) -> string {
	body := strings.trim_space(data_json)
	if len(body) == 0 {
		body = "{}"
	}
	if !strings.has_prefix(body, "{") || !strings.has_suffix(body, "}") {
		return data_json
	}
	inner := strings.trim_space(body[1:len(body) - 1])
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	if len(inner) > 0 {
		strings.write_string(&b, inner)
		strings.write_byte(&b, ',')
	}
	strings.write_string(&b, `"synthetic":true,"pt_source":"sdk","pt_run":`)
	write_json_string(&b, client.playtest.run_id)
	strings.write_string(&b, `,"pt_job":`)
	write_json_string(&b, client.playtest.job_id)
	strings.write_string(&b, `,"persona":`)
	write_json_string(&b, client.playtest.persona)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private)
drop_pending_feedback :: proc(client: ^Client, reason: string) {
	if len(client.pending_feedback) == 0 {
		return
	}
	for fb in client.pending_feedback {
		delete(fb.body)
		fail_feedback(client, reason)
	}
	clear(&client.pending_feedback)
}

// Sends one feedback body (taking ownership of it).
@(private)
send_feedback :: proc(client: ^Client, fb: Pending_Feedback) -> bool {
	t := start_request(client, "/feedback", fb.body, .Session_Token)
	if t == nil {
		delete(fb.body)
		fail_feedback(client, "request_error")
		return false
	}
	t.is_side = true
	t.side = .Feedback
	t.feedback = fb
	append(&client.side, t)
	return true
}

@(private)
send_pending_feedback :: proc(client: ^Client) {
	if len(client.pending_feedback) == 0 {
		return
	}
	pending := client.pending_feedback[:]
	waiting := make([]Pending_Feedback, len(pending), context.temp_allocator)
	copy(waiting, pending)
	clear(&client.pending_feedback)
	for fb in waiting {
		send_feedback(client, fb)
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

// Starts one HTTP request, through libcurl or the installed test transport.
// `body` == "" means GET. Returns nil when the request could not be started.
@(private)
start_request :: proc(client: ^Client, path: string, body: string, auth: Auth) -> ^Transfer {
	url := fmt.tprintf("%s%s", client.api_url, path)
	headers := make([dynamic]string, context.temp_allocator)
	if len(body) > 0 {
		append(&headers, "Content-Type: application/json")
	}
	switch auth {
	case .API_Key:
		append(&headers, fmt.tprintf("X-API-Key: %s", client.ingest_key))
	case .Session_Token:
		append(&headers, fmt.tprintf("X-Session-Token: %s", client.core.session_token))
	}
	if len(client.playtest.token) > 0 {
		append(&headers, fmt.tprintf("X-Ravensight-Playtest: %s", client.playtest.token))
	}

	t := new(Transfer)
	t.body_buf = make([dynamic]u8)
	t.ctx = context
	t.url = strings.clone_to_cstring(url)

	if client.transport.send != nil {
		if !client.transport.send(client.transport.user, t, Http_Request{url = url, headers = headers[:], body = body}) {
			free_transfer(client, t, remove_from_multi = false)
			return nil
		}
		return t
	}

	easy := curl_easy_init()
	if easy == nil {
		free_transfer(client, t, remove_from_multi = false)
		return nil
	}
	t.easy = easy
	for h in headers {
		ch := strings.clone_to_cstring(h, context.temp_allocator)
		t.headers = curl_slist_append(t.headers, ch) // curl copies the string
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
	if t.easy != nil {
		if remove_from_multi {
			curl_multi_remove_handle(client.multi, t.easy)
		}
		curl_easy_cleanup(t.easy)
	}
	if t.headers != nil {
		curl_slist_free_all(t.headers)
	}
	if len(t.feedback.body) > 0 {
		delete(t.feedback.body)
	}
	delete(t.body_buf)
	delete(t.url)
	free(t)
}

@(private)
wait_for_network :: proc(client: ^Client) {
	if client.transport.send != nil {
		if client.transport.idle != nil {
			client.transport.idle(client.transport.user)
		}
		return
	}
	curl_multi_wait(client.multi, nil, 0, 20, nil)
}

@(private)
start_next_protocol_request :: proc(client: ^Client) {
	if client.protocol != nil {
		return
	}
	req, ok := core_next(&client.core, client_now(client))
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
		if len(client.distribution) > 0 {
			strings.write_string(&b, `,"distribution":`)
			write_json_string(&b, client.distribution)
		}
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
		sig := core_on_response(&client.core, Core_Response{status = 0, error_code = "request_error"}, client_now(client))
		dispatch(client, sig)
		return
	}
	t.kind = req.kind
	client.protocol = t
}

@(private)
pump :: proc(client: ^Client) {
	if client.multi == nil {
		return // a test transport answers through finish_transfer directly
	}
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
		finish_transfer(client, client.protocol, status, retry_after_ms)
		return
	}
	for st in client.side {
		if st.easy == easy {
			finish_transfer(client, st, status, retry_after_ms)
			return
		}
	}
}

// Hands a finished transfer to its handler and frees it. `t.body_buf` holds
// the response body; status 0 means no HTTP answer at all.
@(private)
finish_transfer :: proc(client: ^Client, t: ^Transfer, status: int, retry_after_ms: i64) {
	if client.protocol == t {
		client.protocol = nil
		handle_protocol_response(client, t, status, retry_after_ms)
		free_transfer(client, t)
		return
	}
	for st, i in client.side {
		if st == t {
			unordered_remove(&client.side, i)
			handle_side_response(client, t, status)
			free_transfer(client, t)
			return
		}
	}
}

@(private)
error_code_of :: proc(obj: json.Object, is_obj: bool) -> string {
	if is_obj {
		if e, has := obj["error"]; has {
			if s, is_str := e.(json.String); is_str {
				return string(s)
			}
		}
	}
	return ""
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
	res.error_code = error_code_of(obj, is_obj)
	if len(res.error_code) == 0 && status != 0 {
		res.error_code = fmt.bprintf(fallback_buf[:], "http_%d", status)
	}

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

	sig := core_on_response(&client.core, res, client_now(client))
	dispatch(client, sig)
}

@(private)
handle_side_response :: proc(client: ^Client, t: ^Transfer, status: int) {
	parsed, ok := parse_body(t.body_buf[:])
	defer if ok {json.destroy_value(parsed)}
	obj, is_obj := parsed.(json.Object)
	code := error_code_of(obj, is_obj)

	switch t.side {
	case .Feedback:
		if status == 201 {
			if client.cb.on_feedback_submitted != nil {
				client.cb.on_feedback_submitted(client.cb.user)
			}
			return
		}
		if status == 401 && !t.feedback.retried && core_is_active(&client.core) {
			// The session expired: open a new one and send this once more.
			core_invalidate_session(&client.core)
			fb := t.feedback
			fb.retried = true
			t.feedback = {}
			append(&client.pending_feedback, fb)
			core_want_session(&client.core)
			return
		}
		if status == 403 {
			sig: Signals
			core_apply_refusal(&client.core, status, code, &sig)
			dispatch(client, sig)
		}
		reason_buf: [32]u8
		reason := code
		if len(reason) == 0 {
			reason = status != 0 ? fmt.bprintf(reason_buf[:], "http_%d", status) : "offline"
		}
		fail_feedback(client, reason)
	case .Suggestions:
		if status == 401 || status == 403 {
			sig: Signals
			core_apply_refusal(&client.core, status, code, &sig)
			dispatch(client, sig)
		}
		if client.cb.on_suggestions == nil {
			return
		}
		if status == 200 && is_obj {
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
		if status == 200 {
			client.cb.on_suggestions(client.cb.user, "[]", true)
			return
		}
		client.cb.on_suggestions(client.cb.user, "[]", false)
	}
}

@(private)
dispatch :: proc(client: ^Client, sig: Signals) {
	if sig.key_refused && !client.warned_key {
		client.warned_key = true
		log(client, .Warning, INVALID_KEY_WARNING)
	}
	if sig.stopped {
		drop_pending_feedback(client, "disabled")
		if !client.warned_stop {
			client.warned_stop = true
			r := reason_string(core_reason(&client.core))
			log(client, .Warning, fmt.tprintf("Ravensight: playtest run refused by the server (%s), sending stopped for this run.", r))
		}
	}
	if sig.tracking_disabled {
		drop_pending_feedback(client, "disabled")
		if !client.warned_kill {
			client.warned_kill = true
			log(client, .Warning, "Ravensight: tracking is switched off for this game (tracking_disabled), sending stopped for this run.")
		}
		if client.cb.on_tracking_disabled != nil {
			client.cb.on_tracking_disabled(client.cb.user)
		}
	}
	if sig.settings_failed {
		log(client, .Info, fmt.tprintf("Ravensight: settings check failed (%s), assuming tracking enabled.", len(sig.reason) > 0 ? sig.reason : "offline"))
	}
	if sig.session_ready {
		if client.cb.on_session_ready != nil {
			client.cb.on_session_ready(client.cb.user)
		}
		send_pending_feedback(client)
	}
	if sig.session_failed && client.cb.on_session_failed != nil {
		client.cb.on_session_failed(client.cb.user, sig.reason)
	}
	if sig.events_flushed > 0 && client.cb.on_events_flushed != nil {
		client.cb.on_events_flushed(client.cb.user, sig.events_flushed)
	}
	if sig.flush_failed && client.cb.on_flush_failed != nil {
		client.cb.on_flush_failed(client.cb.user, sig.reason)
	}
	if sig.event_dropped && !client.warned_drop {
		client.warned_drop = true
		log(client, .Warning, "Ravensight: the server rejected one event (HTTP 400), it was dropped. Later drops are counted in stats().dropped.")
	}
	sync_reason(client)
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
