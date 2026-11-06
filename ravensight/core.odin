// core.odin - the Ravensight protocol as a pure state machine.
//
// Everything that decides WHAT to send and WHEN lives here: the offline
// queue, batching, the server kill switch, the player's opt-out, a refused
// ingest key, a closed playtest run, session lifetime, 401 re-auth, 429 and
// 503 Retry-After, exponential backoff and oversize batch splitting.
//
// This file performs no I/O and never reads a clock. Time always arrives as
// a `now_ms` argument and network answers arrive as `Core_Response` values,
// so every retry path can be driven deterministically from a unit test.
// The curl transport and the public API live in client.odin.

package ravensight

import "base:runtime"
import "core:fmt"
import "core:strings"

// Server hard limit on POST /track/batch.
MAX_BATCH_SIZE :: 50
// Offline queue cap. Oldest events are dropped first once exceeded.
DEFAULT_QUEUE_CAP :: 500
// First retry delay, doubling per consecutive failure.
DEFAULT_RETRY_MS :: 10_000
// Backoff ceiling: 5 minutes.
MAX_BACKOFF_MS :: 300_000
// Queued events are flushed at least this often.
DEFAULT_FLUSH_INTERVAL_MS :: 5_000
// Assumed session lifetime when the server sends neither expiresAt nor expiresIn.
DEFAULT_SESSION_TTL_MS :: 86_400_000
// A session this close to expiry is treated as already expired.
EXPIRY_SKEW_MS :: 5_000
// Consecutive 401-driven re-auths tolerated before backing off: a batch 401
// opens a new session once, and a second 401 in a row waits for the backoff.
MAX_REAUTH_STREAK :: 1
// Backoff waits are multiplied by a random factor of at least this and below
// 1, so many games that failed together do not retry together. Retry-After
// is never spread.
BACKOFF_MIN_FACTOR :: 0.5
// The saved queue keeps at most this many events across launches.
QUEUE_MAX_EVENTS :: 500
// Events older than this are dropped when the saved queue is read.
QUEUE_MAX_AGE_MS :: 89 * 86_400_000
// The largest event the API accepts: its data serialized as JSON. Bigger
// events are dropped before they are queued.
MAX_EVENT_BYTES :: 8192

// Why the client is not sending, in the vocabulary every Ravensight SDK
// shares. .None means nothing is wrong (ready, or not yet asked).
Reason :: enum {
	None,
	Disabled,            // constructed disabled, set_enabled(false), the player's opt-out, or Opt_In with no yes yet
	Invalid_Key,         // 401, or a 403 that is not one of the codes below; ends the run
	Tracking_Disabled,   // server kill switch, from /settings or a 403 tracking_disabled
	Offline,             // no answer, a timeout, or a 5xx on a batch
	Rate_Limited,        // 429
	Session_Failed,      // POST /session failed, or the playtest token is unusable
	Playtest_Job_Closed, // 403 playtest_job_closed
	No_Key,              // created with no ingest key: inert
}

// The wire form of a Reason, e.g. "invalid_key". "" for .None.
reason_string :: proc(r: Reason) -> string {
	switch r {
	case .None:
		return ""
	case .Disabled:
		return "disabled"
	case .Invalid_Key:
		return "invalid_key"
	case .Tracking_Disabled:
		return "tracking_disabled"
	case .Offline:
		return "offline"
	case .Rate_Limited:
		return "rate_limited"
	case .Session_Failed:
		return "session_failed"
	case .Playtest_Job_Closed:
		return "playtest_job_closed"
	case .No_Key:
		return "no_key"
	}
	return ""
}

Core_Event :: struct {
	name:        string, // owned by the core
	data_json:   string, // owned by the core; pre-serialized JSON object, "" means {}
	timestamp_ms: i64,   // unix milliseconds, captured when the event happened
	is_error:    bool,   // an error event: queued behind gameplay events
	tag:         int,    // the caller's marker, carried untouched (0 for none)
	// The origin object of the session it was queued under, as JSON text,
	// owned; "" when none. Sent with the event when that session is not the
	// current one.
	origin_json:  string,
	// True when the origin is settled (read from the saved queue), so a new
	// session never adopts the event.
	origin_fixed: bool,
}

Request_Kind :: enum {
	None,
	Settings, // GET  /settings        (X-API-Key)
	Session,  // POST /session         (X-API-Key)
	Batch,    // POST /track/batch     (X-Session-Token)
}

// What the transport should send next. For .Batch, `body` is the exact JSON
// request body (owned by the caller, delete it once handed to the transport)
// and `batch_len` is how many queued events it contains. Settings and
// Session bodies are built by the client layer, which owns the identity
// fields the core has no reason to know about.
Core_Request :: struct {
	kind:      Request_Kind,
	body:      string,
	batch_len: int,
}

// One network answer, already parsed by the client layer. `status` 0 means
// the request never got an HTTP answer at all (DNS, connect, timeout);
// the core treats that like any other retryable failure.
Core_Response :: struct {
	status:               int,
	retry_after_ms:       i64,    // parsed Retry-After, 0 when absent
	has_tracking_enabled: bool,   // settings only
	tracking_enabled:     bool,   // settings only
	token:                string, // session only; borrowed, the core clones it
	expires_at_ms:        i64,    // session only; absolute unix ms, 0 when absent
	expires_in_ms:        i64,    // session only; relative ms, 0 when absent
	error_code:           string, // server "error" field or a fallback; borrowed
	index:                int,    // batch 400 only: the refused event, -1 when absent
}

// What happened as a result of a response; the client maps these to the
// user's callbacks. `reason` borrows from the Core_Response and is only
// valid until the response body is freed.
Signals :: struct {
	session_ready:     bool,
	session_failed:    bool,
	tracking_disabled: bool,
	events_flushed:    int, // > 0 when a batch was accepted
	flush_failed:      bool,
	event_dropped:     bool, // a single event was rejected with 400 and dropped
	key_refused:       bool, // the ingest key was refused; the run ended
	stopped:           bool, // permanent stop for the run (refused key, playtest token refused or closed)
	settings_failed:   bool, // GET /settings had no usable answer; tracking assumed on
	reason:            string,
}

Stats :: struct {
	sent:     int,
	dropped:  int,
	flushes:  int,
	sessions: int,
	// Of `dropped`: past the queue cap, older than 89 days when the saved
	// queue was read, and refused by the server.
	dropped_overflow: int,
	dropped_too_old:  int,
	dropped_refused:  int,
}

Core :: struct {
	allocator:             runtime.Allocator,
	max_queue:             int,
	flush_interval_ms:     i64, // < 0 disables the timer (explicit flush only)

	enabled:               bool, // construction option and set_enabled; never saved
	opted_out:             bool, // the player's saved choice (set_tracking_enabled)
	settings_checked:      bool,
	tracking_enabled:      bool, // server kill switch, assumed on until checked
	stopped:               bool, // permanent for the run
	stop_reason:           Reason,
	key_refused:           bool, // the key was refused; stopped is set too
	inert:                 bool, // created with no ingest key; never active
	last_failure:          Reason,
	// Draws in [0, 1) for the backoff jitter. nil (a bare core) means no
	// spread, so the state machine stays deterministic; the client sets the
	// platform's cryptographic random source.
	random:                proc() -> f64,

	session_token:         string, // owned
	session_expires_at_ms: i64,
	session_wanted:        bool, // an explicit request (feedback) needs a session

	in_flight:             Request_Kind,
	in_flight_batch:       int,
	// Bumped whenever the queue is discarded or the session is dropped, so
	// an answer to a request sent before that cannot touch the new state.
	queue_gen:             int,
	in_flight_queue_gen:   int,
	session_gen:           int,
	in_flight_session_gen: int,

	queue:                 [dynamic]Core_Event,
	backoff_ms:            i64,
	next_attempt_at_ms:    i64,
	next_flush_at_ms:      i64,
	flush_requested:       bool,
	batch_limit:           int, // MAX_BATCH_SIZE normally, halved on HTTP 400
	reauth_streak:         int,
	retry_from_server:     bool, // the running wait is a Retry-After
	send_plain:            bool, // after a 415: the next batch goes uncompressed
	queue_dirty:           bool, // the queue changed since the client last saved it
	// The open session's origin as JSON text (owned), "" when none.
	session_origin_json:   string,
	// The tags of events an answer settled for good (delivered or refused),
	// for the client to drain: error capture removes their crash records.
	settled_tags:          [dynamic]int,
	// The last batch went gzip compressed (set by the client).
	last_batch_compressed: bool,

	stats:                 Stats,
}

core_make :: proc(max_queue := DEFAULT_QUEUE_CAP, flush_interval_ms: i64 = DEFAULT_FLUSH_INTERVAL_MS, allocator := context.allocator) -> Core {
	return Core{
		allocator         = allocator,
		max_queue         = max_queue > 0 ? max_queue : DEFAULT_QUEUE_CAP,
		flush_interval_ms = flush_interval_ms,
		enabled           = true,
		tracking_enabled  = true,
		queue             = make([dynamic]Core_Event, allocator),
		settled_tags      = make([dynamic]int, allocator),
		backoff_ms        = DEFAULT_RETRY_MS,
		batch_limit       = MAX_BATCH_SIZE,
	}
}

core_destroy :: proc(c: ^Core) {
	core_clear_queue(c)
	delete(c.queue)
	delete(c.settled_tags)
	core_set_session_origin(c, "")
	if len(c.session_token) > 0 {
		delete(c.session_token, c.allocator)
		c.session_token = ""
	}
}

// active = has a key && enabled && !opted_out && server tracking on && not
// stopped. While not active nothing touches the network.
core_is_active :: proc(c: ^Core) -> bool {
	return !c.inert && c.enabled && !c.opted_out && c.tracking_enabled && !c.stopped
}

// The current reason in the shared vocabulary, most permanent cause first.
core_reason :: proc(c: ^Core) -> Reason {
	if c.inert {
		return .No_Key
	}
	if !c.enabled || c.opted_out {
		return .Disabled
	}
	if c.stopped {
		return c.stop_reason
	}
	if !c.tracking_enabled {
		return .Tracking_Disabled
	}
	return c.last_failure
}

core_is_session_valid :: proc(c: ^Core, now_ms: i64) -> bool {
	return len(c.session_token) > 0 && now_ms < c.session_expires_at_ms - EXPIRY_SKEW_MS
}

// The runtime switch (not saved). Disabling discards anything still queued
// so it does not leave player data sitting in memory.
core_set_enabled :: proc(c: ^Core, enabled: bool) {
	if c.enabled == enabled {
		return
	}
	c.enabled = enabled
	if !enabled {
		core_discard_queue(c)
	}
}

// The player's choice. Opting out discards the queue and stops the timer.
// Saving it is the client layer's job.
core_set_opted_out :: proc(c: ^Core, opted_out: bool) {
	if c.opted_out == opted_out {
		return
	}
	c.opted_out = opted_out
	if opted_out {
		core_discard_queue(c)
	}
}

// Stops the client for the rest of the run: queue cleared, no request ever
// again. Used for a refused key, a playtest token the server refused or a
// closed run.
core_stop :: proc(c: ^Core, reason: Reason) {
	if c.stopped {
		return
	}
	c.stopped = true
	c.stop_reason = reason
	core_discard_queue(c)
}

// The server kill switch: tracking off for the rest of the run.
core_kill :: proc(c: ^Core) {
	c.tracking_enabled = false
	core_discard_queue(c)
}

// Forgets the current session; the next event opens a new one. An answer
// to a session request already in flight is ignored.
core_invalidate_session :: proc(c: ^Core) {
	if len(c.session_token) > 0 {
		delete(c.session_token, c.allocator)
		c.session_token = ""
	}
	c.session_expires_at_ms = 0
	c.session_gen += 1
	c.reauth_streak = 0
	core_set_session_origin(c, "")
}

// Keeps the open session's origin (JSON text, cloned). Events queued while
// no session was open, and not read from the saved queue, belong to it.
core_set_session_origin :: proc(c: ^Core, origin_json: string) {
	if len(c.session_origin_json) > 0 {
		delete(c.session_origin_json, c.allocator)
	}
	c.session_origin_json = len(origin_json) > 0 ? strings.clone(origin_json, c.allocator) : ""
	if len(origin_json) == 0 {
		return
	}
	for &evt in c.queue {
		if !evt.origin_fixed && len(evt.origin_json) == 0 {
			evt.origin_json = strings.clone(origin_json, c.allocator)
			c.queue_dirty = true
		}
	}
}

@(private)
core_free_event :: proc(c: ^Core, evt: Core_Event) {
	delete(evt.name, c.allocator)
	delete(evt.data_json, c.allocator)
	if len(evt.origin_json) > 0 {
		delete(evt.origin_json, c.allocator)
	}
}

// The first queued automatic error outside the batch in flight, or -1.
core_first_automatic :: proc(c: ^Core) -> int {
	from := c.in_flight == .Batch ? c.in_flight_batch : 0
	for i in from ..< len(c.queue) {
		if c.queue[i].is_error {
			return i
		}
	}
	return -1
}

core_queue_cap :: proc(c: ^Core) -> int {
	return clamp(c.max_queue, 1, QUEUE_MAX_EVENTS)
}

// Puts gameplay events before captured errors, keeping each group's order.
// Only for a queue with nothing in flight (the saved queue just read).
core_order_errors_last :: proc(c: ^Core) {
	if c.in_flight == .Batch {
		return
	}
	ordered := make([dynamic]Core_Event, 0, len(c.queue), c.allocator)
	for evt in c.queue {
		if !evt.is_error {
			append(&ordered, evt)
		}
	}
	for evt in c.queue {
		if evt.is_error {
			append(&ordered, evt)
		}
	}
	delete(c.queue)
	c.queue = ordered
}

// Removes the event at `i`, counted as dropped past the cap.
@(private)
core_evict :: proc(c: ^Core, i: int) {
	core_free_event(c, c.queue[i])
	ordered_remove(&c.queue, i)
	c.stats.dropped += 1
	c.stats.dropped_overflow += 1
	c.queue_dirty = true
}

// Appends an event read from the saved queue (strings cloned): its origin
// is settled, and the cap applies, automatic errors first.
core_load_event :: proc(c: ^Core, evt: Core_Event) {
	append(&c.queue, Core_Event{
		name         = strings.clone(evt.name, c.allocator),
		data_json    = strings.clone(evt.data_json, c.allocator),
		timestamp_ms = evt.timestamp_ms,
		origin_json  = len(evt.origin_json) > 0 ? strings.clone(evt.origin_json, c.allocator) : "",
		origin_fixed = true,
		is_error     = evt.is_error,
	})
	for len(c.queue) > core_queue_cap(c) {
		i := core_first_automatic(c)
		core_evict(c, i >= 0 ? i : 0)
	}
}

// Drops everything queued, counting it as dropped.
core_discard_queue :: proc(c: ^Core) {
	c.stats.dropped += len(c.queue)
	core_clear_queue(c)
	c.session_wanted = false
}

// Queues one event. `data_json` must be a serialized JSON object ("" is
// treated as {}); both strings are cloned. Returns false when tracking is
// off (server kill switch or local opt-out).
//
// Gameplay events keep their place ahead of errors: an error is appended at
// the end, and a gameplay event is placed in front of the errors queued
// after the batch in flight, so an error storm can never hold gameplay back.
// When the queue is full the oldest error goes first, then the oldest event;
// a new error never evicts a gameplay event, it is dropped itself.
core_track :: proc(c: ^Core, name: string, data_json: string, now_ms: i64, is_error := false, tag := 0) -> bool {
	if !core_is_active(c) || len(name) == 0 {
		return false
	}

	// Events in the batch in flight are never moved or dropped here.
	floor := c.in_flight == .Batch ? min(c.in_flight_batch, len(c.queue)) : 0
	for len(c.queue) >= core_queue_cap(c) {
		victim := 0
		for i in floor ..< len(c.queue) {
			if c.queue[i].is_error {
				victim = i
				break
			}
		}
		if victim == 0 && (floor == len(c.queue) || !c.queue[floor].is_error) {
			if is_error {
				c.stats.dropped += 1
				c.stats.dropped_overflow += 1
				return false
			}
		}
		if victim == 0 && floor > 0 && floor < len(c.queue) {
			victim = floor
		}
		core_free_event(c, c.queue[victim])
		ordered_remove(&c.queue, victim)
		if victim < floor {
			c.in_flight_batch -= 1
			floor -= 1
		}
		c.stats.dropped += 1
		c.stats.dropped_overflow += 1
	}

	evt := Core_Event{
		name         = strings.clone(name, c.allocator),
		data_json    = strings.clone(data_json, c.allocator),
		timestamp_ms = now_ms,
		is_error     = is_error,
		tag          = tag,
		// The session it was queued under; events queued before a session
		// opens join the next one.
		origin_json  = len(c.session_origin_json) > 0 ? strings.clone(c.session_origin_json, c.allocator) : "",
	}
	at := len(c.queue)
	if !is_error {
		for at > floor && c.queue[at - 1].is_error {
			at -= 1
		}
	}
	inject_at(&c.queue, at, evt)
	c.queue_dirty = true

	if c.next_flush_at_ms == 0 && c.flush_interval_ms >= 0 {
		c.next_flush_at_ms = now_ms + c.flush_interval_ms
	}
	return true
}

// Asks for a flush on the next pump, without waiting for the flush timer.
core_request_flush :: proc(c: ^Core) {
	c.flush_requested = true
}

// Like core_request_flush but also cuts a backoff wait short. A server's
// Retry-After wait always holds. Used at shutdown for the final flush.
core_force_flush :: proc(c: ^Core) {
	c.flush_requested = true
	if !c.retry_from_server {
		c.next_attempt_at_ms = 0
	}
}

// Marks that something outside the queue (a feedback submission) needs a
// session, so one is opened even while the event queue is empty.
core_want_session :: proc(c: ^Core) {
	c.session_wanted = true
}

// Decides the next protocol request, if any. At most one protocol request
// is in flight at a time; calling this marks the returned request as in
// flight until core_on_response is called.
core_next :: proc(c: ^Core, now_ms: i64) -> (req: Core_Request, ok: bool) {
	if c.in_flight != .None || !core_is_active(c) {
		return
	}

	// Boot: read the server kill switch exactly once, before anything else.
	if !c.settings_checked {
		c.in_flight = .Settings
		return Core_Request{kind = .Settings}, true
	}

	if len(c.queue) == 0 {
		c.flush_requested = false
	}

	// Backoff gates both session creation and batch delivery.
	if now_ms < c.next_attempt_at_ms {
		return
	}

	if !core_is_session_valid(c, now_ms) {
		if len(c.queue) > 0 || c.session_wanted {
			c.in_flight = .Session
			c.in_flight_session_gen = c.session_gen
			return Core_Request{kind = .Session}, true
		}
		return
	}

	want_flush := len(c.queue) > 0 &&
		(c.flush_requested ||
			len(c.queue) >= MAX_BATCH_SIZE ||
			(c.flush_interval_ms >= 0 && c.next_flush_at_ms > 0 && now_ms >= c.next_flush_at_ms))
	if !want_flush {
		return
	}

	n := min(c.batch_limit, len(c.queue))
	body := build_batch_body(c.queue[:n], c.allocator, c.session_origin_json)
	c.in_flight = .Batch
	c.in_flight_batch = n
	c.in_flight_queue_gen = c.queue_gen
	return Core_Request{kind = .Batch, body = body, batch_len = n}, true
}

// Feeds the answer for the in-flight request back into the state machine.
core_on_response :: proc(c: ^Core, res: Core_Response, now_ms: i64) -> (sig: Signals) {
	kind := c.in_flight
	c.in_flight = .None

	switch kind {
	case .None:
		return
	case .Settings:
		c.settings_checked = true
		switch {
		case res.status == 200 && res.has_tracking_enabled:
			if !res.tracking_enabled {
				core_kill(c)
				sig.tracking_disabled = true
				sig.reason = "tracking_disabled"
			}
		case res.status == 401 || res.status == 403:
			core_apply_refusal(c, res.status, res.error_code, &sig)
		case:
			// Unreachable or malformed: assume tracking is on, so a
			// settings outage does not silently lose a session.
			if res.status == 0 {
				c.last_failure = .Offline
			}
			sig.settings_failed = true
			sig.reason = res.error_code
		}
	case .Session:
		// session_wanted stays set until a session opens, so feedback that
		// waits for one survives a failed or stale attempt.
		if c.in_flight_session_gen != c.session_gen {
			// The session was dropped (reset_device_id) while this was in
			// flight. Whatever it says belongs to the old identity.
			if res.status == 401 || res.status == 403 {
				core_apply_refusal(c, res.status, res.error_code, &sig)
			}
			return
		}
		switch {
		case res.status == 201 && len(res.token) > 0:
			if len(c.session_token) > 0 {
				delete(c.session_token, c.allocator)
			}
			c.session_token = strings.clone(res.token, c.allocator)
			if res.expires_at_ms > 0 {
				c.session_expires_at_ms = res.expires_at_ms
			} else if res.expires_in_ms > 0 {
				c.session_expires_at_ms = now_ms + res.expires_in_ms
			} else {
				c.session_expires_at_ms = now_ms + DEFAULT_SESSION_TTL_MS
			}
			c.stats.sessions += 1
			c.session_wanted = false
			c.last_failure = .None
			core_reset_backoff(c)
			sig.session_ready = true
		case res.status == 401 || res.status == 403:
			core_apply_refusal(c, res.status, res.error_code, &sig)
			sig.session_failed = true
			sig.reason = reason_string(core_reason(c))
		case res.status == 429:
			core_apply_retry_after(c, res, now_ms)
			c.last_failure = .Rate_Limited
			sig.session_failed = true
			sig.reason = "rate_limited"
		case res.status == 0:
			core_schedule_backoff(c, now_ms)
			c.last_failure = .Offline
			sig.session_failed = true
			sig.reason = "offline"
		case:
			// 201 without a token, 503 storage_unavailable, any other 5xx.
			core_apply_retry_after(c, res, now_ms)
			c.last_failure = .Session_Failed
			sig.session_failed = true
			sig.reason = "session_failed"
		}
	case .Batch:
		n := c.in_flight_batch
		c.in_flight_batch = 0
		if c.in_flight_queue_gen != c.queue_gen {
			// The queue this batch came from was discarded since it went
			// out (opt-out, reset, kill switch); its answer changes nothing.
			if res.status == 403 {
				core_apply_refusal(c, res.status, res.error_code, &sig)
			}
			return
		}

		if res.status != 413 && res.status != 415 {
			c.send_plain = false
		}
		switch {
		case res.status >= 200 && res.status < 300:
			remove := min(n, len(c.queue))
			core_remove_front(c, remove)
			c.stats.sent += remove
			c.stats.flushes += 1
			c.batch_limit = MAX_BATCH_SIZE
			c.reauth_streak = 0
			c.last_failure = .None
			core_reset_backoff(c)
			if len(c.queue) > 0 {
				// Keep draining until the queue is empty.
				c.flush_requested = true
			} else {
				c.flush_requested = false
				c.next_flush_at_ms = 0
			}
			sig.events_flushed = remove
		case res.status == 401:
			// Session expired, revoked, or a signature refused. The batch
			// stays queued and is re-sent under a fresh session, once; a
			// second 401 in a row waits for the backoff.
			if len(c.session_token) > 0 {
				delete(c.session_token, c.allocator)
				c.session_token = ""
			}
			c.session_expires_at_ms = 0
			c.reauth_streak += 1
			if c.reauth_streak > MAX_REAUTH_STREAK {
				core_schedule_backoff(c, now_ms)
			}
			c.flush_requested = true
		case res.status == 403:
			core_apply_refusal(c, res.status, res.error_code, &sig)
			sig.flush_failed = true
			sig.reason = reason_string(core_reason(c))
		case res.status == 429:
			core_apply_retry_after(c, res, now_ms)
			c.last_failure = .Rate_Limited
			sig.flush_failed = true
			sig.reason = "rate_limited"
		case res.status == 400 || res.status == 413 || res.status == 415:
			core_on_batch_refused(c, res, n, &sig)
		case res.status == 0:
			core_schedule_backoff(c, now_ms)
			c.last_failure = .Offline
			sig.flush_failed = true
			sig.reason = "offline"
		case:
			// 5xx, including 503 storage_unavailable with its Retry-After.
			core_apply_retry_after(c, res, now_ms)
			c.last_failure = .Offline
			sig.flush_failed = true
			sig.reason = len(res.error_code) > 0 ? res.error_code : "flush_failed"
		}
	}
	return
}


// Removes the first `count` queued events.
@(private)
core_remove_front :: proc(c: ^Core, count: int) {
	n := min(count, len(c.queue))
	for i in 0 ..< n {
		if c.queue[i].tag != 0 {
			append(&c.settled_tags, c.queue[i].tag)
		}
		core_free_event(c, c.queue[i])
	}
	remove_range(&c.queue, 0, n)
	c.queue_dirty = true
}

// A 400, 413 or 415 for the `n` events at the queue's front:
//   a 400 naming an event by index drops that event, the rest are resent;
//   batch_too_large or a 413 halves the batch;
//   a 415 (or a 413 for one event) is resent uncompressed once, then dropped;
//   any other 400 drops the request's events (only batch_too_large and a
//   413 halve a batch).
@(private)
core_on_batch_refused :: proc(c: ^Core, res: Core_Response, n: int, sig: ^Signals) {
	drop :: proc(c: ^Core, count: int, sig: ^Signals) {
		dropped := min(count, len(c.queue))
		core_remove_front(c, dropped)
		c.stats.dropped += dropped
		c.stats.dropped_refused += dropped
		c.batch_limit = MAX_BATCH_SIZE
		sig.event_dropped = true
	}
	defer c.flush_requested = len(c.queue) > 0
	if res.status == 400 && res.index >= 0 && res.index < n && res.index < len(c.queue) {
		if c.queue[res.index].tag != 0 {
			append(&c.settled_tags, c.queue[res.index].tag)
		}
		core_free_event(c, c.queue[res.index])
		ordered_remove(&c.queue, res.index)
		c.queue_dirty = true
		c.stats.dropped += 1
		c.stats.dropped_refused += 1
		c.batch_limit = MAX_BATCH_SIZE
		sig.event_dropped = true
		return
	}
	if res.status == 415 || (res.status == 413 && n <= 1) {
		// A 413 for one event that went uncompressed is never retried as is.
		if !c.send_plain && (res.status == 415 || c.last_batch_compressed) {
			c.send_plain = true
			return
		}
		c.send_plain = false
		drop(c, n, sig)
		return
	}
	if (res.status == 413 || res.error_code == "batch_too_large") && n > 1 {
		c.batch_limit = max(1, n / 2)
		return
	}
	drop(c, n, sig)
}

// Applies a 401 or 403 from any endpoint (except a 401 on a batch, which
// means the session expired and is handled by re-auth):
//   403 tracking_disabled       kill switch for the run, queue cleared
//   403 invalid_playtest_token  stop for the run, reason session_failed
//   403 playtest_job_closed     stop for the run, reason playtest_job_closed
//   any other 401 or 403        the key was refused: the run ends, queue
//                               cleared, nothing more is sent or retried
core_apply_refusal :: proc(c: ^Core, status: int, error_code: string, sig: ^Signals) {
	if status == 403 {
		switch error_code {
		case "tracking_disabled":
			if c.tracking_enabled {
				core_kill(c)
				sig.tracking_disabled = true
			}
			return
		case "invalid_playtest_token":
			if !c.stopped {
				core_stop(c, .Session_Failed)
				sig.stopped = true
			}
			return
		case "playtest_job_closed":
			if !c.stopped {
				core_stop(c, .Playtest_Job_Closed)
				sig.stopped = true
			}
			return
		}
	}
	if !c.key_refused {
		c.key_refused = true
		sig.key_refused = true
		core_stop(c, .Invalid_Key)
	}
}

// --- Backoff -----------------------------------------------------------------

core_reset_backoff :: proc(c: ^Core) {
	c.backoff_ms = DEFAULT_RETRY_MS
	c.next_attempt_at_ms = 0
}

// Opens a retry window of the current backoff, multiplied by a random factor
// from BACKOFF_MIN_FACTOR up to 1 when a random source is set, then doubles
// the backoff up to the ceiling.
core_schedule_backoff :: proc(c: ^Core, now_ms: i64) {
	wait := min(c.backoff_ms, MAX_BACKOFF_MS)
	if c.random != nil {
		draw := clamp(c.random(), 0, 1)
		factor := BACKOFF_MIN_FACTOR + (1 - BACKOFF_MIN_FACTOR) * draw
		wait = i64(f64(wait) * factor)
	}
	c.retry_from_server = false
	c.next_attempt_at_ms = now_ms + wait
	c.backoff_ms = min(c.backoff_ms * 2, MAX_BACKOFF_MS)
}

// Honors a Retry-After delay when the server sent one, otherwise falls back
// to the exponential backoff. Retry-After does not advance the exponential
// schedule.
core_apply_retry_after :: proc(c: ^Core, res: Core_Response, now_ms: i64) {
	if res.retry_after_ms > 0 {
		c.next_attempt_at_ms = now_ms + res.retry_after_ms
		c.retry_from_server = true
	} else {
		core_schedule_backoff(c, now_ms)
	}
}

core_clear_queue :: proc(c: ^Core) {
	for evt in c.queue {
		core_free_event(c, evt)
	}
	clear(&c.queue)
	c.queue_dirty = true
	c.queue_gen += 1
	c.flush_requested = false
	c.next_flush_at_ms = 0
	c.batch_limit = MAX_BATCH_SIZE
}

// --- Wire format --------------------------------------------------------------

// Builds the exact JSON body for POST /track/batch:
//   {"events":[{"event":"...","data":{...},"timestamp":1700000000123}, ...]}
// Event names are escaped; data_json is spliced in verbatim (it was
// serialized by the client layer already). An event queued under another
// session than `current_origin` carries that session's origin, verbatim.
build_batch_body :: proc(events: []Core_Event, allocator := context.allocator, current_origin := "") -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"events":[`)
	for evt, i in events {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `{"event":`)
		write_json_string(&b, evt.name)
		strings.write_string(&b, `,"data":`)
		strings.write_string(&b, len(evt.data_json) > 0 ? evt.data_json : "{}")
		strings.write_string(&b, `,"timestamp":`)
		strings.write_i64(&b, evt.timestamp_ms)
		if len(evt.origin_json) > 0 && evt.origin_json != current_origin {
			strings.write_string(&b, `,"origin":`)
			strings.write_string(&b, evt.origin_json)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

// Writes `s` as a JSON string literal, escaping quotes, backslashes and
// control characters. Multi-byte UTF-8 sequences pass through untouched
// (every byte of one is >= 0x80, so the byte-wise scan cannot split them).
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case '\b':
			strings.write_string(b, `\b`)
		case '\f':
			strings.write_string(b, `\f`)
		case:
			if ch < 0x20 {
				fmt.sbprintf(b, `\u%04x`, ch)
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
	strings.write_byte(b, '"')
}

// Accepts a bare host or a full /api/v1 base and always returns the
// versioned base: trim whitespace, strip every trailing "/", strip a
// trailing "/api/v1", then append "/api/v1". Empty means DEFAULT_API_URL.
normalize_api_url :: proc(url: string, allocator := context.allocator) -> string {
	raw := strings.trim_space(url)
	raw = strings.trim_right(raw, "/")
	if len(raw) == 0 {
		raw = DEFAULT_API_URL
	}
	raw = strings.trim_suffix(raw, "/api/v1")
	return strings.concatenate({raw, "/api/v1"}, allocator)
}
