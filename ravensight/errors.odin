// errors.odin - automatic error capture and the log trail.
//
// Odin has no global error hook: errors reach the game through the logger
// and the assertion failure procedure in `context`, which is scope based. So
// "on by default" is one host line at the top of main, after create():
//
//     context = ravensight.install_error_capture()
//
// which returns the caller's context with two values replaced:
//
//   * context.logger: ravensight.logger(previous). Every line goes on to the
//     previous logger exactly as before. .Error lines are captured as
//     warnings and .Fatal lines as critical, with the source location as the
//     stack (rs_source "log"). .Warning and lower go into the trail, an
//     in-memory ring of the last 20 lines.
//   * context.assertion_failure_proc: ravensight.assertion_failure_handler(previous).
//     A failed assert or a panic is scrubbed and written synchronously next
//     to the storage file, then the previous procedure runs as before (the
//     process still dies the way it would have). The next launch sends it
//     as one critical event, rs_source "crash".
//
// Nothing is captured without a key, before consent, after opt-out, or
// while the game's errorCapture.enabled is false (absent means on). Until
// the settings or session answer arrives, at most 5 captures are held in
// memory; they are sent once the answer says capture is on and discarded
// unsent otherwise. Captures are scrubbed on the device, cut to the
// contract's lengths, and capped per run: 30 captures, 3 per local dedupe
// key, 10 trails, and a token bucket of 6 a minute. Over a cap is dropped
// silently. The trail is attached only when errorCapture.trail is true.
//
// Threads: the logger may be called from any thread. It only copies the
// line into a fixed-size inbox under a mutex; tick() turns the inbox into
// events on the game thread. Lines logged by the SDK itself, or from inside
// tick(), shutdown() or a Ravensight callback, are never captured.

package ravensight

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

ERROR_SOURCE_LOG :: "log"
ERROR_SOURCE_CRASH :: "crash"
MAX_ERROR_TYPE_CHARS :: 100
MAX_TRAIL_CHARS :: 1500
MAX_TRAIL_LINE_CHARS :: 120
TRAIL_LINES :: 20
// Per-run device caps. Over any of them a capture is dropped silently.
MAX_CAPTURES_PER_RUN :: 30
MAX_CAPTURES_PER_KEY :: 3
MAX_TRAILS_PER_RUN :: 10
CAPTURE_BUCKET_SIZE :: 6
CAPTURE_REFILL_MS :: 10_000 // one token back every 10 seconds, 6 a minute
// Captures held in memory until the first settings or session answer.
MAX_BOOT_CAPTURES :: 5
// Captures waiting for the next tick(); past this they are dropped.
CAPTURE_INBOX_SIZE :: 16
// The crash file sits next to the storage file.
CRASH_FILE_SUFFIX :: ".crash"
MAX_CRASH_FILE_BYTES :: 16_384

// What install_error_capture changes in a context, for hosts that prefer to
// set the two fields themselves.
Error_Capture :: struct {
	logger:                 runtime.Logger,
	assertion_failure_proc: runtime.Assertion_Failure_Proc,
}

// --- Fixed-size text, so the hooks never allocate ---------------------------------

@(private)
Fixed_Text :: struct($N: int) {
	n:   int,
	buf: [N]u8,
}

@(private)
fixed_set :: proc(f: ^Fixed_Text($N), s: string) {
	n := min(len(s), N)
	// Never end inside a UTF-8 sequence.
	if n < len(s) {
		for n > 0 && s[n] & 0xC0 == 0x80 {
			n -= 1
		}
	}
	copy(f.buf[:], s[:n])
	f.n = n
}

@(private)
fixed_get :: proc(f: ^Fixed_Text($N)) -> string {
	return string(f.buf[:f.n])
}

@(private)
Raw_Capture :: struct {
	severity:   string, // a constant: SEVERITY_WARNING or SEVERITY_CRITICAL
	source:     string, // a constant
	error_type: string, // a constant
	at_ms:      i64,
	trail_seq:  u64, // trail lines older than this belong to the capture
	line:       i32,
	column:     i32,
	message:    Fixed_Text(1024),
	file:       Fixed_Text(512),
	procedure:  Fixed_Text(128),
}

@(private)
Trail_Line :: struct {
	seq:   u64,
	at_ms: i64,
	level: runtime.Logger_Level,
	text:  Fixed_Text(256),
}

// One capture ready to send: scrubbed and cut. Strings are owned by
// whoever made it (temp, or the client allocator while held).
@(private)
Prepared_Capture :: struct {
	severity:   string,
	source:     string,
	error_type: string,
	message:    string,
	stack:      string,
	trail:      string,
	key:        string,
}

// Per-client capture state, game thread only.
@(private)
Capture_Client :: struct {
	bound:         bool, // this client receives the hooks' captures
	known:         bool, // a settings or session answer said what errorCapture is
	enabled:       bool,
	trail:         bool,
	held:          [dynamic]Prepared_Capture,
	count:         int,
	trails:        int,
	keys:          map[string]int,
	tokens:        f64,
	refilled_ms:   i64,
	start_ms:      i64,
	crash_path:    string, // owned; "" when there is no storage file
}

// Shared between the hooks (any thread) and the bound client (game thread).
@(private)
Capture_Global :: struct {
	mutex:       sync.Mutex,
	client:      ^Client,
	armed:       bool, // the bound client may capture right now
	clock_user:  rawptr,
	clock:       proc(user: rawptr) -> i64,
	inbox:       [CAPTURE_INBOX_SIZE]Raw_Capture,
	inbox_len:   int,
	trail:       [TRAIL_LINES]Trail_Line,
	trail_seq:   u64, // lines ever written; the ring holds the last TRAIL_LINES
	start_ms:    i64,
	crash_path:  Fixed_Text(1024),
	prev_assert: runtime.Assertion_Failure_Proc,
}

@(private)
capture_global: Capture_Global

// Set while the SDK itself runs on this thread: its log lines, tick(),
// shutdown() and the callbacks they make are never captured.
@(private, thread_local)
capture_quiet: int

// Set while the crash path runs, so a failure inside it cannot recurse.
@(private, thread_local)
capture_crashing: bool

// --- The hooks ---------------------------------------------------------------------

@(private)
Forward_Logger :: struct {
	previous: runtime.Logger,
}

// A logger that forwards every line to `previous` unchanged and captures
// .Error (as a warning) and .Fatal (as critical). .Warning and lower go into
// the trail. Its lowest level is Info or the previous logger's, whichever
// is lower; lines below the previous logger's own lowest level are not
// forwarded. The small forwarding record comes from the heap allocator;
// destroy_logger frees it.
logger :: proc(previous: runtime.Logger) -> runtime.Logger {
	if previous.procedure == capture_logger_proc {
		return previous // already installed; never wrap twice
	}
	fw := new(Forward_Logger, runtime.heap_allocator())
	fw.previous = previous
	lowest := previous.procedure == nil ? runtime.Logger_Level.Info : min(previous.lowest_level, runtime.Logger_Level.Info)
	return runtime.Logger{procedure = capture_logger_proc, data = fw, lowest_level = lowest, options = previous.options}
}

// Frees a logger made by logger() and returns the one it wrapped. Any other
// logger is returned unchanged.
destroy_logger :: proc(l: runtime.Logger) -> runtime.Logger {
	if l.procedure != capture_logger_proc || l.data == nil {
		return l
	}
	fw := (^Forward_Logger)(l.data)
	previous := fw.previous
	free(fw, runtime.heap_allocator())
	return previous
}

// Remembers `previous` and returns the SDK's assertion failure procedure,
// which persists the failure and then calls `previous` (or the runtime's
// default when it is nil).
assertion_failure_handler :: proc(previous: runtime.Assertion_Failure_Proc) -> runtime.Assertion_Failure_Proc {
	if previous != capture_assertion_failure_proc {
		sync.mutex_lock(&capture_global.mutex)
		capture_global.prev_assert = previous
		sync.mutex_unlock(&capture_global.mutex)
	}
	return capture_assertion_failure_proc
}

// The caller's context with the capture logger and assertion procedure
// installed, chaining to whatever was there. Install once, after create():
//
//     context = ravensight.install_error_capture()
//
// Calling it again on a context that already has them changes nothing.
install_error_capture :: proc() -> runtime.Context {
	c := context
	values := error_capture_values()
	c.logger = values.logger
	c.assertion_failure_proc = values.assertion_failure_proc
	return c
}

// The two values install_error_capture sets, built over the caller's context.
error_capture_values :: proc() -> Error_Capture {
	return Error_Capture{
		logger                 = logger(context.logger),
		assertion_failure_proc = assertion_failure_handler(context.assertion_failure_proc),
	}
}

@(private)
capture_logger_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	fw := (^Forward_Logger)(data)
	if fw != nil {
		prev := fw.previous
		if prev.procedure != nil && level >= prev.lowest_level {
			prev.procedure(prev.data, level, text, prev.options, location)
		}
	}
	if capture_quiet > 0 || capture_crashing || strings.has_prefix(text, "Ravensight: ") {
		return
	}
	capture_record(level, text, location)
}

@(private)
capture_assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	previous := capture_global.prev_assert
	if !capture_crashing {
		capture_crashing = true
		capture_persist_crash(prefix, message, loc)
	}
	if previous != nil && previous != capture_assertion_failure_proc {
		previous(prefix, message, loc)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

@(private)
capture_clock :: proc() -> i64 {
	if capture_global.clock != nil {
		return capture_global.clock(capture_global.clock_user)
	}
	return now_ms()
}

// Called by the logger on any thread: copies the line, nothing else.
@(private)
capture_record :: proc(level: runtime.Logger_Level, text: string, loc: runtime.Source_Code_Location) {
	sync.mutex_lock(&capture_global.mutex)
	defer sync.mutex_unlock(&capture_global.mutex)
	if !capture_global.armed {
		return
	}
	at := capture_clock()
	if level < .Error {
		slot := &capture_global.trail[capture_global.trail_seq % TRAIL_LINES]
		slot.seq = capture_global.trail_seq
		slot.at_ms = at
		slot.level = level
		fixed_set(&slot.text, text)
		capture_global.trail_seq += 1
		return
	}
	if capture_global.inbox_len >= CAPTURE_INBOX_SIZE {
		return
	}
	raw := &capture_global.inbox[capture_global.inbox_len]
	capture_global.inbox_len += 1
	raw^ = {}
	raw.severity = level >= .Fatal ? SEVERITY_CRITICAL : SEVERITY_WARNING
	raw.source = ERROR_SOURCE_LOG
	raw.error_type = level >= .Fatal ? "log.Fatal" : "log.Error"
	raw.at_ms = at
	raw.trail_seq = capture_global.trail_seq
	raw.line = loc.line
	raw.column = loc.column
	fixed_set(&raw.message, text)
	fixed_set(&raw.file, loc.file_path)
	fixed_set(&raw.procedure, loc.procedure)
}

// The trail lines older than `upto`, oldest first, formatted, scrubbed, each
// cut to 120 characters, newest kept within 1,500. Caller holds the mutex.
@(private)
capture_trail_text :: proc(upto: u64, start_ms: i64) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	first := upto > TRAIL_LINES ? upto - TRAIL_LINES : 0
	for seq in first ..< upto {
		slot := &capture_global.trail[seq % TRAIL_LINES]
		if slot.seq != seq {
			continue // overwritten by a newer line
		}
		append(&lines, trail_line(slot.at_ms - start_ms, slot.level, fixed_get(&slot.text)))
	}
	return join_trail(lines[:])
}

// One trail line: `+<ms> <level> <text>`, scrubbed and cut to 120.
@(private)
trail_line :: proc(ms: i64, level: runtime.Logger_Level, text: string) -> string {
	name := "debug"
	switch {
	case level >= .Fatal:
		name = "fatal"
	case level >= .Error:
		name = "error"
	case level >= .Warning:
		name = "warning"
	case level >= .Info:
		name = "info"
	}
	flat, _ := strings.replace_all(text, "\n", " ", context.temp_allocator)
	line := fmt.tprintf("+%d %s %s", max(ms, 0), name, flat)
	return scrub_field(line, MAX_TRAIL_LINE_CHARS)
}

// Joins trail lines oldest first, dropping the oldest until it fits 1,500.
@(private)
join_trail :: proc(lines: []string) -> string {
	lines := lines
	if len(lines) > TRAIL_LINES {
		lines = lines[len(lines) - TRAIL_LINES:]
	}
	for len(lines) > 0 {
		joined := strings.join(lines, "\n", context.temp_allocator)
		if strings.rune_count(joined) <= MAX_TRAIL_CHARS {
			return joined
		}
		lines = lines[1:]
	}
	return ""
}

// The local dedupe key's message part: digit runs read as one placeholder.
@(private)
message_template :: proc(message: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	in_digits := false
	for i in 0 ..< len(message) {
		c := message[i]
		if is_digit_byte(c) {
			if !in_digits {
				strings.write_byte(&b, '#')
			}
			in_digits = true
			continue
		}
		in_digits = false
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// Scrubs and cuts one capture. Pure. Allocates in the temp allocator.
prepare_capture :: proc(
	severity, source, error_type, message, file, procedure: string,
	line, column: i32,
	trail := "",
) -> Prepared_Capture {
	msg := scrub_field(message, MAX_ERROR_MESSAGE_CHARS)
	stack := ""
	if len(file) > 0 || len(procedure) > 0 {
		frame := fmt.tprintf("at %s (%s:%d:%d)", len(procedure) > 0 ? procedure : "?", file, line, column)
		stack = scrub_field(frame, MAX_ERROR_STACK_CHARS)
	}
	kind := cut_runes(error_type, MAX_ERROR_TYPE_CHARS)
	// The first frame's file and procedure, without line and column.
	frame_key := fmt.tprintf("%s#%s", scrub_field(file, MAX_ERROR_STACK_CHARS), cut_runes(procedure, MAX_ERROR_TYPE_CHARS))
	return Prepared_Capture{
		severity   = severity,
		source     = source,
		error_type = kind,
		message    = msg,
		stack      = stack,
		trail      = trail,
		key        = strings.concatenate({kind, "\n", message_template(msg), "\n", frame_key}, context.temp_allocator),
	}
}

// --- The crash path ----------------------------------------------------------------

@(private)
Crash_Record :: struct {
	v:          int,
	severity:   string,
	source:     string,
	error_type: string,
	message:    string,
	stack:      string,
	trail:      string,
	key:        string,
}

// Writes a failed assertion to the crash file, synchronously, when the
// bound client may capture. Scrubbed before it reaches the disk.
@(private)
capture_persist_crash :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> bool {
	context.allocator = context.temp_allocator
	locked := false
	for _ in 0 ..< 1000 {
		if sync.mutex_try_lock(&capture_global.mutex) {
			locked = true
			break
		}
	}
	if !locked {
		return false // never wait on a lock this thread may already hold
	}
	armed := capture_global.armed
	path := strings.clone(fixed_get(&capture_global.crash_path))
	trail := armed ? capture_trail_text(capture_global.trail_seq, capture_global.start_ms) : ""
	sync.mutex_unlock(&capture_global.mutex)
	if !armed || len(path) == 0 {
		return false
	}
	kind := len(prefix) > 0 ? prefix : "assertion"
	p := prepare_capture(SEVERITY_CRITICAL, ERROR_SOURCE_CRASH, kind, message, loc.file_path, loc.procedure, loc.line, loc.column, trail)
	return write_crash_file(path, p)
}

@(private)
write_crash_file :: proc(path: string, p: Prepared_Capture) -> bool {
	rec := Crash_Record{1, p.severity, p.source, p.error_type, p.message, p.stack, p.trail, p.key}
	data, err := json.marshal(rec, allocator = context.temp_allocator)
	if err != nil {
		return false
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil {
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// Reads and removes the crash file of an earlier run. Only a client that may
// capture keeps it (held until the answer); any other drops it unsent.
@(private)
capture_load_crash :: proc(cl: ^Client) {
	path := cl.capture.crash_path
	if len(path) == 0 || !os.exists(path) {
		return
	}
	defer os.remove(path)
	if !capture_should_run(cl) {
		return
	}
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil || info.size > MAX_CRASH_FILE_BYTES {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	rec: Crash_Record
	if json.unmarshal(data, &rec, allocator = context.temp_allocator) != nil || rec.v != 1 {
		return
	}
	// Scrubbed and cut again: the file is on the player's disk.
	p := Prepared_Capture{
		severity   = SEVERITY_CRITICAL,
		source     = ERROR_SOURCE_CRASH,
		error_type = cut_runes(rec.error_type, MAX_ERROR_TYPE_CHARS),
		message    = scrub_field(rec.message, MAX_ERROR_MESSAGE_CHARS),
		stack      = scrub_field(rec.stack, MAX_ERROR_STACK_CHARS),
		trail      = scrub_field(rec.trail, MAX_TRAIL_CHARS),
		key        = rec.key,
	}
	capture_accept(cl, p)
}

// --- The client side (game thread) -----------------------------------------------------

// Capture runs while the client is active (a key, enabled, consent, not
// opted out, tracking on, not stopped) and no answer has switched it off.
@(private)
capture_should_run :: proc(cl: ^Client) -> bool {
	return core_is_active(&cl.core) && (!cl.capture.known || cl.capture.enabled)
}

@(private)
capture_init :: proc(cl: ^Client) {
	cl.capture.held = make([dynamic]Prepared_Capture, cl.allocator)
	cl.capture.keys = make(map[string]int, allocator = cl.allocator)
	cl.capture.tokens = CAPTURE_BUCKET_SIZE
	cl.capture.start_ms = client_now(cl)
	cl.capture.refilled_ms = cl.capture.start_ms
	if len(cl.storage_path) > 0 {
		cl.capture.crash_path = strings.concatenate({cl.storage_path, CRASH_FILE_SUFFIX}, cl.allocator)
	}
}

// Makes this client the one the hooks feed. The last client created wins.
@(private)
capture_bind :: proc(cl: ^Client) {
	sync.mutex_lock(&capture_global.mutex)
	if capture_global.client != nil && capture_global.client != cl {
		capture_global.client.capture.bound = false
	}
	capture_global.client = cl
	capture_global.clock = cl.transport.now
	capture_global.clock_user = cl.transport.user
	capture_global.start_ms = cl.capture.start_ms
	capture_global.armed = false
	capture_global.inbox_len = 0
	capture_global.trail_seq = 0
	capture_global.trail = {}
	fixed_set(&capture_global.crash_path, cl.capture.crash_path)
	sync.mutex_unlock(&capture_global.mutex)
	cl.capture.bound = true
	capture_sync(cl)
}

@(private)
capture_unbind :: proc(cl: ^Client) {
	sync.mutex_lock(&capture_global.mutex)
	if capture_global.client == cl {
		capture_global.client = nil
		capture_global.armed = false
		capture_global.inbox_len = 0
		capture_global.trail_seq = 0
		capture_global.trail = {}
		capture_global.clock = nil
		capture_global.clock_user = nil
		fixed_set(&capture_global.crash_path, "")
	}
	sync.mutex_unlock(&capture_global.mutex)
	cl.capture.bound = false
}

// Arms or disarms the hooks to match the client. Turning off forgets the
// trail, the inbox and anything held.
@(private)
capture_sync :: proc(cl: ^Client) {
	on := capture_should_run(cl)
	if cl.capture.bound {
		sync.mutex_lock(&capture_global.mutex)
		if capture_global.client == cl && capture_global.armed != on {
			capture_global.armed = on
			if !on {
				capture_global.inbox_len = 0
				capture_global.trail_seq = 0
				capture_global.trail = {}
			}
		}
		sync.mutex_unlock(&capture_global.mutex)
	}
	if !on {
		capture_drop_held(cl)
	}
}

@(private)
capture_drop_held :: proc(cl: ^Client) {
	for p in cl.capture.held {
		capture_free(cl, p)
	}
	clear(&cl.capture.held)
}

@(private)
capture_free :: proc(cl: ^Client, p: Prepared_Capture) {
	delete(p.error_type, cl.allocator)
	delete(p.message, cl.allocator)
	delete(p.stack, cl.allocator)
	delete(p.trail, cl.allocator)
	delete(p.key, cl.allocator)
}

// The errorCapture switches from a settings or session answer. `present`
// false (no errorCapture object) means capture on and the trail off.
@(private)
capture_answer :: proc(cl: ^Client, present, enabled, trail: bool) {
	cl.capture.known = true
	cl.capture.enabled = !present || enabled
	cl.capture.trail = present && trail
	capture_sync(cl)
	if len(cl.capture.held) == 0 {
		return
	}
	held := cl.capture.held[:]
	if capture_should_run(cl) {
		for p in held {
			capture_emit(cl, p)
		}
	}
	for p in held {
		capture_free(cl, p)
	}
	clear(&cl.capture.held)
}

// Turns the inbox into events. Game thread, from tick() and shutdown().
@(private)
capture_drain :: proc(cl: ^Client) {
	if !cl.capture.bound {
		return
	}
	ready := make([dynamic]Prepared_Capture, context.temp_allocator)
	sync.mutex_lock(&capture_global.mutex)
	if capture_global.client == cl {
		for i in 0 ..< capture_global.inbox_len {
			raw := &capture_global.inbox[i]
			trail := capture_trail_text(raw.trail_seq, capture_global.start_ms)
			append(&ready, prepare_capture(raw.severity, raw.source, raw.error_type, fixed_get(&raw.message), fixed_get(&raw.file), fixed_get(&raw.procedure), raw.line, raw.column, trail))
		}
		capture_global.inbox_len = 0
	}
	sync.mutex_unlock(&capture_global.mutex)
	for p in ready {
		capture_accept(cl, p)
	}
}

// Holds a capture until the first answer, or sends it.
@(private)
capture_accept :: proc(cl: ^Client, p: Prepared_Capture) {
	if !capture_should_run(cl) {
		return
	}
	if cl.capture.known {
		capture_emit(cl, p)
		return
	}
	if len(cl.capture.held) >= MAX_BOOT_CAPTURES {
		return
	}
	append(&cl.capture.held, Prepared_Capture{
		severity   = p.severity,
		source     = p.source,
		error_type = strings.clone(p.error_type, cl.allocator),
		message    = strings.clone(p.message, cl.allocator),
		stack      = strings.clone(p.stack, cl.allocator),
		trail      = strings.clone(p.trail, cl.allocator),
		key        = strings.clone(p.key, cl.allocator),
	})
}

// Applies the device caps and queues one error event.
@(private)
capture_emit :: proc(cl: ^Client, p: Prepared_Capture) -> bool {
	if cl.capture.count >= MAX_CAPTURES_PER_RUN {
		return false
	}
	if cl.capture.keys[p.key] >= MAX_CAPTURES_PER_KEY {
		return false
	}
	now := client_now(cl)
	if now > cl.capture.refilled_ms {
		cl.capture.tokens = min(f64(CAPTURE_BUCKET_SIZE), cl.capture.tokens + f64(now - cl.capture.refilled_ms) / CAPTURE_REFILL_MS)
		cl.capture.refilled_ms = now
	}
	if cl.capture.tokens < 1 {
		return false
	}

	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("error")
	props["rs_severity"] = json.String(p.severity)
	props["rs_message"] = json.String(p.message)
	props["rs_source"] = json.String(p.source)
	if len(p.stack) > 0 {
		props["rs_stack"] = json.String(p.stack)
	}
	if len(p.error_type) > 0 {
		props["rs_error_type"] = json.String(p.error_type)
	}
	with_trail := cl.capture.trail && len(p.trail) > 0 && cl.capture.trails < MAX_TRAILS_PER_RUN
	if with_trail {
		props["rs_trail"] = json.String(p.trail)
	}
	capture_quiet += 1
	ok := track_event(cl, "error", props, true)
	capture_quiet -= 1
	if !ok {
		return false
	}
	cl.capture.count += 1
	cl.capture.tokens -= 1
	if with_trail {
		cl.capture.trails += 1
	}
	if count, has := cl.capture.keys[p.key]; has {
		cl.capture.keys[p.key] = count + 1
	} else {
		cl.capture.keys[strings.clone(p.key, cl.allocator)] = 1
	}
	return true
}

// A new identity: nothing captured under the old one is kept or sent.
@(private)
capture_reset :: proc(cl: ^Client) {
	capture_drop_held(cl)
	if cl.capture.bound {
		sync.mutex_lock(&capture_global.mutex)
		if capture_global.client == cl {
			capture_global.inbox_len = 0
			capture_global.trail_seq = 0
			capture_global.trail = {}
		}
		sync.mutex_unlock(&capture_global.mutex)
	}
	if len(cl.capture.crash_path) > 0 && os.exists(cl.capture.crash_path) {
		os.remove(cl.capture.crash_path)
	}
}

@(private)
capture_destroy :: proc(cl: ^Client) {
	capture_unbind(cl)
	capture_drop_held(cl)
	delete(cl.capture.held)
	for k in cl.capture.keys {
		delete(k, cl.allocator)
	}
	delete(cl.capture.keys)
	delete(cl.capture.crash_path, cl.allocator)
}

// Reads `errorCapture: { enabled, trail }` from a settings or session answer.
@(private)
parse_error_capture :: proc(obj: json.Object) -> (present, enabled, trail: bool) {
	v, has := obj["errorCapture"]
	if !has {
		return false, true, false
	}
	ec, is_obj := v.(json.Object)
	if !is_obj {
		return false, true, false
	}
	enabled = true
	if e, ok := ec["enabled"].(json.Boolean); ok {
		enabled = bool(e)
	}
	if t, ok := ec["trail"].(json.Boolean); ok {
		trail = bool(t)
	}
	return true, enabled, trail
}
