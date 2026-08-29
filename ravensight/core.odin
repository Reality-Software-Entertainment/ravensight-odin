// core.odin - the Ravensight protocol as a pure state machine.
//
// Everything that decides WHAT to send and WHEN lives here: the offline
// queue, batching, the server kill switch, session lifetime, 401 re-auth,
// 429 Retry-After, exponential backoff and oversize batch splitting.
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
// Consecutive 401-driven re-auths tolerated before backing off, so a server
// that rejects every fresh token cannot cause a hot request loop.
MAX_REAUTH_STREAK :: 2

Core_Event :: struct {
	name:        string, // owned by the core
	data_json:   string, // owned by the core; pre-serialized JSON object, "" means {}
	timestamp_s: i64,    // unix seconds, captured when the event happened
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
	reason:            string,
}

Stats :: struct {
	sent:     int,
	dropped:  int,
	flushes:  int,
	sessions: int,
}

Core :: struct {
	allocator:             runtime.Allocator,
	max_queue:             int,
	flush_interval_ms:     i64, // < 0 disables the timer (explicit flush only)

	enabled:               bool, // local opt-out (privacy toggle)
	settings_checked:      bool,
	tracking_enabled:      bool, // server kill switch, assumed on until checked

	session_token:         string, // owned
	session_expires_at_ms: i64,
	session_wanted:        bool, // an explicit request (feedback) needs a session

	in_flight:             Request_Kind,
	in_flight_batch:       int,

	queue:                 [dynamic]Core_Event,
	backoff_ms:            i64,
	next_attempt_at_ms:    i64,
	next_flush_at_ms:      i64,
	flush_requested:       bool,
	batch_limit:           int, // MAX_BATCH_SIZE normally, halved on HTTP 400
	reauth_streak:         int,

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
		backoff_ms        = DEFAULT_RETRY_MS,
		batch_limit       = MAX_BATCH_SIZE,
	}
}

core_destroy :: proc(c: ^Core) {
	core_clear_queue(c)
	delete(c.queue)
	if len(c.session_token) > 0 {
		delete(c.session_token, c.allocator)
		c.session_token = ""
	}
}

core_is_active :: proc(c: ^Core) -> bool {
	return c.enabled && c.tracking_enabled
}

core_is_session_valid :: proc(c: ^Core, now_ms: i64) -> bool {
	return len(c.session_token) > 0 && now_ms < c.session_expires_at_ms - EXPIRY_SKEW_MS
}

// Local opt-in and opt-out. Disabling discards anything still queued so an
// opt-out does not leave player data sitting in memory.
core_set_enabled :: proc(c: ^Core, enabled: bool) {
	if c.enabled == enabled {
		return
	}
	c.enabled = enabled
	if !enabled {
		c.stats.dropped += len(c.queue)
		core_clear_queue(c)
	}
}

// Queues one event. `data_json` must be a serialized JSON object ("" is
// treated as {}); both strings are cloned. Returns false when tracking is
// off (server kill switch or local opt-out).
core_track :: proc(c: ^Core, name: string, data_json: string, now_ms: i64) -> bool {
	if !core_is_active(c) || len(name) == 0 {
		return false
	}

	for len(c.queue) >= c.max_queue {
		// Drop oldest so the newest always survive.
		evt := c.queue[0]
		delete(evt.name, c.allocator)
		delete(evt.data_json, c.allocator)
		ordered_remove(&c.queue, 0)
		c.stats.dropped += 1
	}

	append(&c.queue, Core_Event{
		name        = strings.clone(name, c.allocator),
		data_json   = strings.clone(data_json, c.allocator),
		timestamp_s = now_ms / 1000,
	})

	if c.next_flush_at_ms == 0 && c.flush_interval_ms >= 0 {
		c.next_flush_at_ms = now_ms + c.flush_interval_ms
	}
	return true
}

// Asks for a flush on the next pump, without waiting for the flush timer.
core_request_flush :: proc(c: ^Core) {
	c.flush_requested = true
}

// Like core_request_flush but also clears any backoff gate. Used at
// shutdown for the final best-effort flush.
core_force_flush :: proc(c: ^Core) {
	c.flush_requested = true
	c.next_attempt_at_ms = 0
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
	if c.in_flight != .None || !c.enabled {
		return
	}

	// Boot: read the server kill switch exactly once, before anything else.
	if !c.settings_checked {
		c.in_flight = .Settings
		return Core_Request{kind = .Settings}, true
	}
	if !c.tracking_enabled {
		return
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
	body := build_batch_body(c.queue[:n], c.allocator)
	c.in_flight = .Batch
	c.in_flight_batch = n
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
		if res.status == 200 && res.has_tracking_enabled {
			c.tracking_enabled = res.tracking_enabled
		} else {
			// Unreachable or malformed: assume tracking is on, so a
			// settings outage does not silently lose a session.
			c.tracking_enabled = true
		}
		if !c.tracking_enabled {
			core_clear_queue(c)
			sig.tracking_disabled = true
			sig.reason = "server"
		}
	case .Session:
		c.session_wanted = false
		if res.status == 201 && len(res.token) > 0 {
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
			core_reset_backoff(c)
			sig.session_ready = true
		} else if res.status == 429 {
			core_apply_retry_after(c, res, now_ms)
			sig.session_failed = true
			sig.reason = len(res.error_code) > 0 ? res.error_code : "rate_limited"
		} else {
			core_schedule_backoff(c, now_ms)
			sig.session_failed = true
			sig.reason = len(res.error_code) > 0 ? res.error_code : "session_failed"
		}
	case .Batch:
		n := c.in_flight_batch
		c.in_flight_batch = 0

		switch {
		case res.status == 202:
			remove := min(n, len(c.queue))
			for i in 0 ..< remove {
				delete(c.queue[i].name, c.allocator)
				delete(c.queue[i].data_json, c.allocator)
			}
			remove_range(&c.queue, 0, remove)
			c.stats.sent += remove
			c.stats.flushes += 1
			c.batch_limit = MAX_BATCH_SIZE
			c.reauth_streak = 0
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
			// Session expired or revoked. The batch stays queued and is
			// re-sent as soon as a fresh session is issued.
			if len(c.session_token) > 0 {
				delete(c.session_token, c.allocator)
				c.session_token = ""
			}
			c.session_expires_at_ms = 0
			c.reauth_streak += 1
			if c.reauth_streak > MAX_REAUTH_STREAK {
				// The server rejects even freshly issued tokens; stop the
				// hot re-auth loop and retry later.
				core_schedule_backoff(c, now_ms)
			}
			c.flush_requested = true
		case res.status == 429:
			core_apply_retry_after(c, res, now_ms)
			sig.flush_failed = true
			sig.reason = len(res.error_code) > 0 ? res.error_code : "rate_limited"
		case res.status == 400:
			if n > 1 {
				// Batch rejected as oversize: halve and retry immediately.
				c.batch_limit = max(1, n / 2)
				c.flush_requested = true
			} else {
				// A single event the server will never take. Drop it so the
				// rest of the queue is not blocked behind it forever.
				if len(c.queue) > 0 {
					delete(c.queue[0].name, c.allocator)
					delete(c.queue[0].data_json, c.allocator)
					ordered_remove(&c.queue, 0)
					c.stats.dropped += 1
				}
				c.batch_limit = MAX_BATCH_SIZE
				c.flush_requested = len(c.queue) > 0
				sig.event_dropped = true
			}
		case:
			core_schedule_backoff(c, now_ms)
			sig.flush_failed = true
			sig.reason = len(res.error_code) > 0 ? res.error_code : "flush_failed"
		}
	}
	return
}

// --- Backoff -----------------------------------------------------------------

core_reset_backoff :: proc(c: ^Core) {
	c.backoff_ms = DEFAULT_RETRY_MS
	c.next_attempt_at_ms = 0
}

core_schedule_backoff :: proc(c: ^Core, now_ms: i64) {
	c.next_attempt_at_ms = now_ms + c.backoff_ms
	c.backoff_ms = min(c.backoff_ms * 2, MAX_BACKOFF_MS)
}

// Honors a Retry-After delay when the server sent one, otherwise falls back
// to the exponential backoff. Retry-After does not advance the exponential
// schedule.
core_apply_retry_after :: proc(c: ^Core, res: Core_Response, now_ms: i64) {
	if res.retry_after_ms > 0 {
		c.next_attempt_at_ms = now_ms + res.retry_after_ms
	} else {
		core_schedule_backoff(c, now_ms)
	}
}

core_clear_queue :: proc(c: ^Core) {
	for evt in c.queue {
		delete(evt.name, c.allocator)
		delete(evt.data_json, c.allocator)
	}
	clear(&c.queue)
}

// --- Wire format --------------------------------------------------------------

// Builds the exact JSON body for POST /track/batch:
//   {"events":[{"event":"...","data":{...},"timestamp":123}, ...]}
// Event names are escaped; data_json is spliced in verbatim (it was
// serialized by the client layer already).
build_batch_body :: proc(events: []Core_Event, allocator := context.allocator) -> string {
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
		strings.write_i64(&b, evt.timestamp_s)
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
// versioned base with no trailing slash.
normalize_api_url :: proc(url: string, allocator := context.allocator) -> string {
	raw := strings.trim_space(url)
	raw = strings.trim_right(raw, "/")
	if len(raw) == 0 {
		raw = strings.trim_right(DEFAULT_API_URL, "/")
	}
	if strings.has_suffix(raw, "/api/v1") {
		return strings.clone(raw, allocator)
	}
	return strings.concatenate({raw, "/api/v1"}, allocator)
}
