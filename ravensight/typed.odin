// typed.odin - typed event helpers and the opt-in health summary.
//
// The helpers are thin: each builds the reserved rs_* property set and calls
// track(), so queueing, batching, retries, opt-out and the playtest tags are
// unchanged and a helper returns exactly what track() returns. Bad input is
// passed through, never refused here; the server flags it with rs_invalid.

package ravensight

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strings"

// Values for track_resource's `flow`.
FLOW_SOURCE :: "source"
FLOW_SINK :: "sink"

// Values for track_progression's `status`.
STATUS_START :: "start"
STATUS_COMPLETE :: "complete"
STATUS_FAIL :: "fail"

// Values for track_error's `severity`.
SEVERITY_DEBUG :: "debug"
SEVERITY_INFO :: "info"
SEVERITY_WARNING :: "warning"
SEVERITY_ERROR :: "error"
SEVERITY_CRITICAL :: "critical"

MAX_ERROR_MESSAGE_CHARS :: 200
MAX_ERROR_STACK_CHARS :: 2000
// The most frame samples kept per session.
MAX_HEALTH_SAMPLES :: 600
HEALTH_SAMPLE_INTERVAL_MS :: 1_000

@(private)
process_start_ms: i64

@(init)
@(private)
record_process_start :: proc "contextless" () {
	context = runtime.default_context()
	process_start_ms = now_ms()
}

// Extra properties a helper merges first; the reserved rs_* keys win.
Extra :: map[string]json.Value

// Caller keys first, then the reserved keys written over them.
@(private)
typed_track :: proc(client: ^Client, name: string, props: map[string]json.Value, extra: Extra) -> bool {
	merged := make(map[string]json.Value, allocator = context.temp_allocator)
	for k, v in extra {
		merged[k] = v
	}
	for k, v in props {
		merged[k] = v
	}
	return track(client, name, merged)
}

// Cuts to at most `max` code points without allocating.
@(private)
cut_runes :: proc(s: string, max: int) -> string {
	n := 0
	for _, i in s {
		if n == max {
			return s[:i]
		}
		n += 1
	}
	return s
}

// A purchase. `amount` is whole minor units of `currency` (499 is 4.99), an
// integer or a digit string; `currency` is upper-cased. `cart` and
// `transaction_id` are left out when empty. Event name defaults to "purchase".
track_purchase :: proc(
	client: ^Client,
	amount: $T,
	currency, item_type, item_id: string,
	cart := "",
	transaction_id := "",
	extra: Extra = nil,
	name := "",
) -> bool {
	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("purchase")
	when intrinsics.type_is_integer(T) {
		props["rs_amount"] = json.Integer(amount)
	} else when intrinsics.type_is_float(T) {
		props["rs_amount"] = json.Float(amount) // sent as given; the server flags it
	} else when intrinsics.type_is_string(T) {
		props["rs_amount"] = json.String(amount)
	} else {
		#panic("track_purchase: amount must be an integer or a digit string")
	}
	props["rs_currency"] = json.String(strings.to_upper(currency, context.temp_allocator))
	props["rs_item_type"] = json.String(item_type)
	props["rs_item_id"] = json.String(item_id)
	if len(cart) > 0 {
		props["rs_cart"] = json.String(cart)
	}
	if len(transaction_id) > 0 {
		props["rs_transaction_id"] = json.String(transaction_id)
	}
	return typed_track(client, len(name) > 0 ? name : "purchase", props, extra)
}

// A resource moving into the economy (FLOW_SOURCE) or out of it (FLOW_SINK).
// Event name defaults to "resource_source" or "resource_sink".
track_resource :: proc(
	client: ^Client,
	flow, resource: string,
	amount: f64,
	item_type := "",
	item_id := "",
	extra: Extra = nil,
	name := "",
) -> bool {
	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("resource")
	props["rs_flow"] = json.String(flow)
	props["rs_resource"] = json.String(resource)
	props["rs_amount"] = json.Float(amount)
	if len(item_type) > 0 {
		props["rs_item_type"] = json.String(item_type)
	}
	if len(item_id) > 0 {
		props["rs_item_id"] = json.String(item_id)
	}
	default_name := "resource"
	if flow == FLOW_SOURCE {
		default_name = "resource_source"
	} else if flow == FLOW_SINK {
		default_name = "resource_sink"
	}
	return typed_track(client, len(name) > 0 ? name : default_name, props, extra)
}

// A progression step: STATUS_START, STATUS_COMPLETE or STATUS_FAIL on the
// node p1 (optionally p2, p3). `score` is left out when nil. Event name
// defaults to "progression_start", "progression_complete" or "progression_fail".
track_progression :: proc(
	client: ^Client,
	status, p1: string,
	p2 := "",
	p3 := "",
	score: Maybe(f64) = nil,
	extra: Extra = nil,
	name := "",
) -> bool {
	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("progression")
	props["rs_status"] = json.String(status)
	props["rs_p1"] = json.String(p1)
	if len(p2) > 0 {
		props["rs_p2"] = json.String(p2)
	}
	if len(p3) > 0 {
		props["rs_p3"] = json.String(p3)
	}
	score_value, has_score := score.?
	if has_score {
		props["rs_score"] = json.Float(score_value)
	}
	default_name := "progression"
	if status == STATUS_START || status == STATUS_COMPLETE || status == STATUS_FAIL {
		default_name = strings.concatenate({"progression_", status}, context.temp_allocator)
	}
	return typed_track(client, len(name) > 0 ? name : default_name, props, extra)
}

// An error report. `message` is cut to 200 characters and `stack` to 2000.
// Event name defaults to "error".
track_error :: proc(
	client: ^Client,
	severity, message: string,
	stack := "",
	extra: Extra = nil,
	name := "",
) -> bool {
	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("error")
	props["rs_severity"] = json.String(severity)
	props["rs_message"] = json.String(cut_runes(message, MAX_ERROR_MESSAGE_CHARS))
	if len(stack) > 0 {
		props["rs_stack"] = json.String(cut_runes(stack, MAX_ERROR_STACK_CHARS))
	}
	return typed_track(client, len(name) > 0 ? name : "error", props, extra)
}

// --- Health sampling -------------------------------------------------------------

// Median and 10th percentile (nearest rank) of frames per second. `ok` is
// false for no samples. Sorts a copy; the input is untouched.
@(private)
health_summary :: proc(samples: []f64) -> (median, p10: f64, ok: bool) {
	n := len(samples)
	if n == 0 {
		return 0, 0, false
	}
	sorted := slice.clone(samples, context.temp_allocator)
	slice.sort(sorted)
	if n % 2 == 1 {
		median = sorted[n / 2]
	} else {
		median = (sorted[n / 2 - 1] + sorted[n / 2]) / 2
	}
	rank := int(math.ceil(0.1 * f64(n)))
	p10 = sorted[max(rank, 1) - 1]
	return median, p10, true
}

@(private)
round2 :: proc(x: f64) -> f64 {
	return math.round(x * 100) / 100
}

// Called from tick(). Takes at most one sample per second of client time.
@(private)
sample_frame :: proc(client: ^Client, dt: f64) {
	now := client_now(client)
	frame_s := dt
	if frame_s <= 0 && client.health_last_tick_ms > 0 {
		frame_s = f64(now - client.health_last_tick_ms) / 1000
	}
	client.health_last_tick_ms = now
	if frame_s <= 0 || now - client.health_last_sample_ms < HEALTH_SAMPLE_INTERVAL_MS {
		return
	}
	client.health_last_sample_ms = now
	client.health_seen += 1
	fps := 1 / frame_s
	if len(client.health_samples) < MAX_HEALTH_SAMPLES {
		append(&client.health_samples, fps)
	} else if j := rand.int_max(client.health_seen); j < MAX_HEALTH_SAMPLES {
		client.health_samples[j] = fps
	}
}

// Sends the one health event of the session. Nothing without samples.
@(private)
send_health :: proc(client: ^Client) {
	if !client.performance || client.health_sent || len(client.health_samples) == 0 {
		return
	}
	median, p10, ok := health_summary(client.health_samples[:])
	if !ok {
		return
	}
	client.health_sent = true
	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("health")
	props["rs_fps_median"] = json.Float(round2(median))
	props["rs_fps_p10"] = json.Float(round2(p10))
	props["rs_boot_ms"] = json.Integer(client.boot_ms)
	typed_track(client, "health", props, nil)
}

@(private)
boot_ms_now :: proc() -> i64 {
	return max(now_ms() - process_start_ms, 0)
}
