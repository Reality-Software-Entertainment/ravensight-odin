// delivery.odin - the delivery contract's client side: the saved queue,
// origins, gzip, signed requests and the device fields on the session.
//
// The saved queue is one file per ingest key beside the storage file,
// queue-<16 hex>.json, the hex being the 64-bit FNV-1a hash of the key. It
// is format version 2: one group per session, with that session's origin
// exactly as the server sent it. It is written whenever the queue changed
// (once per tick, and at once after an answer removed events) to a
// temporary file renamed over the old one, read once at create(), and
// deleted when the player opts out or resets the identity.

package ravensight

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

QUEUE_FORMAT_VERSION :: 2
// Request bodies of at least this many bytes are sent gzip compressed.
GZIP_MIN_BYTES :: 1024
// Each device field is at most this many characters.
DEVICE_FIELD_MAX_CHARS :: 128

// 64-bit FNV-1a of the bytes of `text`, as 16 lowercase hex characters.
fnv1a64_hex :: proc(text: string, allocator := context.allocator) -> string {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(text) {
		h ~= u64(text[i])
		h *= 0x100000001b3
	}
	return fmt.aprintf("%016x", h, allocator = allocator)
}

// This key's saved queue, beside the storage file. "" without storage (a
// playtest run).
queue_path :: proc(client: ^Client, allocator := context.temp_allocator) -> string {
	if len(client.storage_path) == 0 {
		return ""
	}
	name := fmt.tprintf("queue-%s.json", fnv1a64_hex(client.ingest_key, context.temp_allocator))
	path, _ := filepath.join({filepath.dir(client.storage_path), name}, allocator)
	return path
}

// Where the attribution "sent" flag lives, beside the storage file.
attribution_flag_path :: proc(client: ^Client) -> string {
	if len(client.storage_path) == 0 {
		return ""
	}
	path, _ := filepath.join({filepath.dir(client.storage_path), "ravensight_attribution"}, context.temp_allocator)
	return path
}

// A replacement for the backup exclusion, set by a test on its own thread;
// nil means exclude_from_backup.
@(private, thread_local)
backup_exclude_override: proc(path: string) -> (bool, bool)

// Keeps a file out of backups where the system has a way to say so, with
// one retry. A second failure logs one warning that names no file contents.
@(private)
exclude_with_retry :: proc(client: ^Client, path: string) {
	exclude := backup_exclude_override != nil ? backup_exclude_override : exclude_from_backup
	done, supported := exclude(path)
	if supported && !done {
		done, _ = exclude(path)
		if !done {
			log(client, .Warning, "Ravensight: could not keep the event queue out of backups.")
		}
	}
}

// Deletes the queue file and any temporary file a write left behind.
@(private)
remove_queue_files :: proc(path: string) {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	for p in ([]string{path, tmp}) {
		if os.exists(p) {
			os.remove(p)
		}
	}
}

// Writes `text` to a temporary file and renames it over `path`, so a partial
// write never replaces a good file. A failed write or rename deletes the
// temporary file.
write_atomic :: proc(client: ^Client, path: string, text: string) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]u8)text) != nil {
		if os.exists(tmp) {
			os.remove(tmp)
		}
		return false
	}
	// The queue holds origin stamps and scrubbed captures: keep it out of
	// backups. Set on the new file, so the rename carries it over.
	exclude_with_retry(client, tmp)
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// Saves the queue when it changed: only while collecting (or `stopping`,
// the last write before the core lets go of it) and once it was read.
persist_queue :: proc(client: ^Client, stopping := false) {
	if !client.core.queue_dirty && !stopping {
		return
	}
	path := queue_path(client)
	if len(path) == 0 || !client.queue_loaded || !(stopping || core_is_active(&client.core)) {
		return
	}
	client.core.queue_dirty = false
	if len(client.core.queue) == 0 {
		remove_queue_files(path)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"version":%d,"groups":[`, QUEUE_FORMAT_VERSION)
	last := ""
	written := 0
	for evt in client.core.queue {
		// A captured crash keeps its own crash record (errors.odin), which the
		// next launch reads again: saving it here as well would send it twice.
		if evt.tag != 0 {
			continue
		}
		i := written
		written += 1
		if i == 0 || evt.origin_json != last {
			if i > 0 {
				strings.write_string(&b, `]},`)
			}
			strings.write_byte(&b, '{')
			if len(evt.origin_json) > 0 {
				strings.write_string(&b, `"origin":`)
				strings.write_string(&b, evt.origin_json)
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, `"events":[`)
			last = evt.origin_json
		} else {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `{"event":`)
		write_json_string(&b, evt.name)
		fmt.sbprintf(&b, `,"timestamp":%d,"data":`, evt.timestamp_ms)
		strings.write_string(&b, data_for_disk(evt))
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `]}]}`)
	if written == 0 {
		remove_queue_files(path)
		return
	}
	if !write_atomic(client, path, strings.to_string(b)) {
		log(client, .Warning, "Ravensight: could not save the event queue.")
	}
}

// Reads the saved queue once: its events go ahead of anything queued after.
// A missing, unreadable, malformed or unknown version file is an empty
// queue. Version 1 groups have no origin. Events older than 89 days are
// dropped, then the oldest past the cap.
load_queue :: proc(client: ^Client) {
	if client.queue_loaded {
		return
	}
	client.queue_loaded = true
	path := queue_path(client)
	if len(path) == 0 {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	// A file from an older version, or one copied in, is kept out of
	// backups too.
	exclude_with_retry(client, path)
	parsed, perr := json.parse(data, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil {
		client.core.queue_dirty = true
		return
	}
	doc, is_obj := parsed.(json.Object)
	version := is_obj ? json_number_i64(doc["version"]) : 0
	groups, has_groups := doc["groups"].(json.Array)
	if !is_obj || (version != 1 && version != 2) || !has_groups {
		client.core.queue_dirty = true
		return
	}
	cutoff := client_now(client) - QUEUE_MAX_AGE_MS
	for g in groups {
		group, ok := g.(json.Object)
		if !ok {
			continue
		}
		origin_json := ""
		if version == 2 {
			if origin, has := group["origin"].(json.Object); has {
				text, err := json.marshal(json.Value(origin), {sort_maps_by_key = true}, context.temp_allocator)
				if err == nil {
					origin_json = string(text)
				}
			}
		}
		events, _ := group["events"].(json.Array)
		for e in events {
			obj, eok := e.(json.Object)
			name, nok := obj["event"].(json.String)
			if !eok || !nok || len(name) == 0 {
				continue
			}
			ts: i64
			#partial switch v in obj["timestamp"] {
			case json.Integer:
				ts = i64(v)
			case json.Float:
				ts = i64(v)
			case:
				continue
			}
			// Below 10^12 a timestamp is in seconds (an older SDK's queue).
			ts_ms := ts >= 1_000_000_000_000 ? ts : ts * 1000
			if ts_ms < cutoff {
				client.core.stats.dropped += 1
				client.core.stats.dropped_too_old += 1
				continue
			}
			data_json := "{}"
			if d, dok := obj["data"].(json.Object); dok {
				text, err := json.marshal(json.Value(d), {sort_maps_by_key = true}, context.temp_allocator)
				if err == nil {
					data_json = string(text)
				}
			}
			core_load_event(&client.core, Core_Event{
				name = string(name), data_json = data_json, timestamp_ms = ts,
				origin_json = origin_json, is_error = is_automatic_error_json(data_json),
			})
		}
	}
	// Gameplay goes before captured errors.
	core_order_errors_last(&client.core)
	client.core.queue_dirty = true
}

// The data as written to the queue file: a capture's rs_trail is never
// written to disk.
@(private)
data_for_disk :: proc(evt: Core_Event) -> string {
	data := len(evt.data_json) > 0 ? evt.data_json : "{}"
	if !strings.contains(data, `"rs_trail"`) {
		return data
	}
	parsed, err := json.parse(transmute([]u8)data, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	if err != nil {
		return "{}"
	}
	obj, ok := parsed.(json.Object)
	if !ok {
		return "{}"
	}
	delete_key(&obj, "rs_trail")
	text, merr := json.marshal(json.Value(obj), {sort_maps_by_key = true}, context.temp_allocator)
	return merr == nil ? string(text) : "{}"
}

// An error the SDK captured by itself: rs_kind "error" with an rs_source
// that is not "manual", the same test as the automatic error capture's.
is_automatic_error_json :: proc(data_json: string) -> bool {
	if !strings.contains(data_json, `"rs_source"`) {
		return false
	}
	parsed, err := json.parse(transmute([]u8)data_json, spec = .JSON, allocator = context.temp_allocator)
	if err != nil {
		return false
	}
	obj, ok := parsed.(json.Object)
	kind, _ := obj["rs_kind"].(json.String)
	source, has_source := obj["rs_source"].(json.String)
	return ok && kind == "error" && has_source && source != "manual"
}

// Takes the session answer's origin (as JSON text with its fields exactly as
// received, keys sorted) and signing secret. The secret stays in memory only.
adopt_session_extras :: proc(client: ^Client, obj: json.Object) {
	origin_json := ""
	if origin, has := obj["origin"].(json.Object); has {
		text, err := json.marshal(json.Value(origin), {sort_maps_by_key = true}, context.temp_allocator)
		if err == nil {
			origin_json = string(text)
		}
	}
	core_set_session_origin(&client.core, origin_json)
	clear_signing(client)
	if signing, has := obj["signing"].(json.Object); has {
		algorithm, _ := signing["algorithm"].(json.String)
		secret, has_secret := signing["secret"].(json.String)
		if algorithm == "HMAC-SHA256" && json_number_i64(signing["version"]) == 1 && has_secret {
			client.signing_secret = strings.clone(string(secret), client.allocator)
			if _, has_time := signing["serverTime"]; has_time {
				client.clock_offset_s = json_number_i64(signing["serverTime"]) - client_now(client) / 1000
			} else {
				client.clock_offset_s = 0
			}
		}
	}
}

clear_signing :: proc(client: ^Client) {
	if len(client.signing_secret) > 0 {
		delete(client.signing_secret, client.allocator)
	}
	client.signing_secret = ""
}

// The contract's signature: lowercase hex HMAC-SHA256 over
// "v1:" + t + ":" + body, keyed with the secret's bytes as text.
sign_body :: proc(secret: string, t: i64, body: string, allocator := context.temp_allocator) -> string {
	message := fmt.tprintf("v1:%d:%s", t, body)
	digest: [32]u8
	hmac.sum(hash.Algorithm.SHA256, digest[:], transmute([]u8)message, transmute([]u8)secret)
	return string(hex.encode(digest[:], allocator))
}

// The device fields for the session body, cleaned: printable, trimmed, at
// most DEVICE_FIELD_MAX_CHARS characters; empty ones left out. "" when none.
device_json :: proc(model, os_version, gpu: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	count := 0
	fields := [3][2]string{{"model", model}, {"osVersion", os_version}, {"gpu", gpu}}
	for f in fields {
		value := clean_device_field(f[1])
		if len(value) == 0 {
			continue
		}
		strings.write_byte(&b, count == 0 ? '{' : ',')
		write_json_string(&b, f[0])
		strings.write_byte(&b, ':')
		write_json_string(&b, value)
		count += 1
	}
	if count == 0 {
		return ""
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

clean_device_field :: proc(raw: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in raw {
		if r >= 0x20 && r != 0x7f {
			strings.write_rune(&b, r)
		}
	}
	value := strings.trim_space(strings.to_string(b))
	return strings.trim_space(cut_runes(value, DEVICE_FIELD_MAX_CHARS))
}

// An error event's text fields and the length within which each counts one
// byte a character toward the 8 KB ceiling (delivery contract, section 6).
@(private)
ERROR_TEXT_CAPS :: [3]struct{key: string, cap: int}{{"rs_message", 200}, {"rs_stack", 2000}, {"rs_trail", 1500}}

// The size of an event's data as the server measures it: its JSON in UTF-8
// bytes, except that an error event's rs_message, rs_stack and rs_trail,
// each within its cap (in UTF-16 units), count one byte a character. Odin's
// JSON writer escapes a character outside the Basic Multilingual Plane as a
// 12 byte surrogate pair where the server's JSON keeps its 4 UTF-8 bytes, so
// each such pair counts 8 bytes less.
event_bytes :: proc(data_json: string) -> int {
	size := len(data_json)
	for i := 0; i + 5 < len(data_json); i += 1 {
		if data_json[i] == '\\' && data_json[i + 1] == 'u' && (data_json[i + 2] == 'd' || data_json[i + 2] == 'D') {
			switch data_json[i + 3] {
			case '8', '9', 'a', 'b', 'A', 'B':
				size -= 8
				i += 11
			}
		} else if data_json[i] == '\\' {
			i += 1
		}
	}
	if !strings.contains(data_json, `"rs_kind"`) {
		return size
	}
	parsed, err := json.parse(transmute([]u8)data_json, spec = .JSON, allocator = context.temp_allocator)
	if err != nil {
		return size
	}
	obj, ok := parsed.(json.Object)
	kind, _ := obj["rs_kind"].(json.String)
	if !ok || kind != "error" {
		return size
	}
	for f in ERROR_TEXT_CAPS {
		value, is_str := obj[f.key].(json.String)
		if !is_str {
			continue
		}
		units := utf16_length(string(value))
		if units <= f.cap {
			escaped := strings.builder_make(context.temp_allocator)
			write_json_string(&escaped, string(value))
			size -= strings.builder_len(escaped) - units
		}
	}
	return size
}

// Characters as the server counts them: UTF-16 code units.
utf16_length :: proc(s: string) -> int {
	n := 0
	for r in s {
		n += r > 0xFFFF ? 2 : 1
	}
	return n
}
