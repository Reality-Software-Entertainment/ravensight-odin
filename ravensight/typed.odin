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
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
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
typed_track :: proc(client: ^Client, name: string, props: map[string]json.Value, extra: Extra, is_error := false) -> bool {
	merged := make(map[string]json.Value, allocator = context.temp_allocator)
	for k, v in extra {
		merged[k] = v
	}
	for k, v in props {
		merged[k] = v
	}
	return track_event(client, name, merged, is_error)
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
	return typed_track(client, len(name) > 0 ? name : "error", props, extra, is_error = true)
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

// --- Ads and attribution --------------------------------------------------------
//
// Unlike the helpers above, these check their fields and refuse a malformed
// event locally (returning false, one log line), so revenue without a
// currency or a fraction of a micro is never sent.

// Values for track_ad's `format` and `result`.
AD_FORMATS :: [?]string{"banner", "interstitial", "rewarded", "native", "app_open", "other"}
AD_RESULTS :: [?]string{"shown", "clicked", "failed", "rewarded"}

Ad_Options :: struct {
	// The game's own placement name, 1 to 100 characters; "" leaves it out.
	placement:      string,
	// Revenue of this impression in MICROS of `currency` (1,000,000 is one
	// major unit) as a digit string of 1 to 18 digits, on a "shown" ad only.
	// Convert a mediation callback's double with micros_from_revenue.
	revenue_micros: string,
	// ISO 4217, three letters, required with revenue and refused without it.
	currency:       string,
	// The event name, default "rs_ad".
	name:           string,
	extra:          Extra,
}

@(private)
in_list :: proc(value: string, list: []string) -> bool {
	for v in list {
		if v == value {
			return true
		}
	}
	return false
}

@(private)
refuse_typed :: proc(client: ^Client, kind: string, why: string) -> bool {
	log(client, .Warning, fmt.tprintf("Ravensight: %s event not sent: %s.", kind, why))
	return false
}

@(private)
all_digits :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// One ad lifecycle step. `network` is the network that served the ad (1 to
// 64 characters), `format` one of AD_FORMATS, `result` one of AD_RESULTS.
// Returns false, sending nothing, when anything is malformed.
track_ad :: proc(client: ^Client, network, format, result: string, opts := Ad_Options{}) -> bool {
	if client == nil {
		return false
	}
	formats, results := AD_FORMATS, AD_RESULTS
	if len(network) == 0 || utf16_length(network) > 64 || !in_list(format, formats[:]) || !in_list(result, results[:]) {
		return refuse_typed(client, "ad", "network is 1 to 64 characters, with a known format and result")
	}
	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("ad")
	props["rs_ad_network"] = json.String(network)
	props["rs_ad_format"] = json.String(format)
	props["rs_ad_result"] = json.String(result)
	if len(opts.placement) > 0 {
		if utf16_length(opts.placement) > 100 {
			return refuse_typed(client, "ad", "placement is at most 100 characters")
		}
		props["rs_ad_placement"] = json.String(opts.placement)
	}
	if len(opts.revenue_micros) > 0 {
		if !all_digits(opts.revenue_micros) || len(opts.revenue_micros) > 18 {
			return refuse_typed(client, "ad", "revenue_micros is a digit string of 1 to 18 digits")
		}
		if result != "shown" {
			return refuse_typed(client, "ad", "revenue goes on a shown ad only")
		}
		if len(opts.currency) != 3 || !strings_is_letters(opts.currency) {
			return refuse_typed(client, "ad", "revenue needs a three letter currency")
		}
		props["rs_revenue_micros"] = json.String(opts.revenue_micros)
		props["rs_currency"] = json.String(strings.to_upper(opts.currency, context.temp_allocator))
	} else if len(opts.currency) > 0 {
		return refuse_typed(client, "ad", "a currency is sent only with revenue")
	}
	return typed_track(client, len(opts.name) > 0 ? opts.name : "rs_ad", props, opts.extra)
}

// A paid impression: track_ad with result "shown".
track_ad_revenue :: proc(client: ^Client, network, format, placement, revenue_micros, currency: string) -> bool {
	return track_ad(client, network, format, "shown", Ad_Options{placement = placement, revenue_micros = revenue_micros, currency = currency})
}

@(private)
strings_is_letters :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		ch := s[i]
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z') {
			return false
		}
	}
	return true
}

// Micros from decimal text in major units, worked on the digits so no float
// is ever multiplied: "0.0015" is "1500", "1.23456789" is "1234568" (half up
// at the seventh decimal). ok = false for anything that is not a plain
// non-negative decimal or does not fit 18 digits.
micros_from_decimal_string :: proc(text: string, allocator := context.allocator) -> (micros: string, ok: bool) {
	t := strings.trim_space(text)
	whole, fraction := t, ""
	if dot := strings.index_byte(t, '.'); dot >= 0 {
		whole, fraction = t[:dot], t[dot + 1:]
	}
	if len(whole) == 0 && len(fraction) == 0 {
		return "", false
	}
	if (len(whole) > 0 && !all_digits(whole)) || (len(fraction) > 0 && !all_digits(fraction)) {
		return "", false
	}
	digits := make([dynamic]u8, context.temp_allocator)
	append(&digits, ..transmute([]u8)whole)
	for i in 0 ..< 6 {
		append(&digits, i < len(fraction) ? fraction[i] : '0')
	}
	round_up := len(fraction) > 6 && fraction[6] >= '5'
	if round_up {
		i := len(digits) - 1
		for i >= 0 && digits[i] == '9' {
			digits[i] = '0'
			i -= 1
		}
		if i >= 0 {
			digits[i] += 1
		} else {
			inject_at(&digits, 0, '1')
		}
	}
	start := 0
	for start < len(digits) - 1 && digits[start] == '0' {
		start += 1
	}
	if len(digits) - start > 18 {
		return "", false
	}
	return strings.clone(string(digits[start:]), allocator), true
}

// Micros from a mediation callback's revenue double in major units: the
// double is formatted to 6 decimals, then converted on its digits. ok =
// false for a negative, infinite or NaN value.
micros_from_revenue :: proc(value: f64, allocator := context.allocator) -> (micros: string, ok: bool) {
	if math.is_nan(value) || math.is_inf(value) || value < 0 {
		return "", false
	}
	return micros_from_decimal_string(fmt.tprintf("%.6f", value), allocator)
}

// Where this device was acquired. `source` is required (1 to 64: "utm",
// "store_referrer", "organic" or a partner name); network 1 to 100,
// campaign, adset and creative 1 to 200; touch_time_ms epoch milliseconds,
// 0 to leave it out. Empty fields are left out.
Attribution :: struct {
	source:        string,
	network:       string,
	campaign:      string,
	adset:         string,
	creative:      string,
	touch_time_ms: i64,
	// The event name, default "rs_attribution".
	name:          string,
}

// Sends where this install was acquired, once per install: a flag saved
// beside the storage file stops later calls, and reset_device_id clears it.
// Returns true when queued; false when already sent, not tracking, or a
// field is malformed.
set_attribution :: proc(client: ^Client, a: Attribution) -> bool {
	if client == nil || !core_is_active(&client.core) {
		return false
	}
	flag := attribution_flag_path(client)
	if len(flag) > 0 && os.exists(flag) {
		return false
	}
	if len(a.source) == 0 || utf16_length(a.source) > 64 {
		return refuse_typed(client, "attribution", "source is 1 to 64 characters")
	}
	props := make(map[string]json.Value, allocator = context.temp_allocator)
	props["rs_kind"] = json.String("attribution")
	props["rs_attr_source"] = json.String(a.source)
	fields := [4]struct{value, key: string, cap: int}{
		{a.network, "rs_attr_network", 100}, {a.campaign, "rs_campaign", 200},
		{a.adset, "rs_adset", 200}, {a.creative, "rs_creative", 200},
	}
	for f in fields {
		if len(f.value) == 0 {
			continue
		}
		if utf16_length(f.value) > f.cap {
			return refuse_typed(client, "attribution", fmt.tprintf("%s is at most %d characters", f.key, f.cap))
		}
		props[f.key] = json.String(f.value)
	}
	if a.touch_time_ms < 0 || a.touch_time_ms > 9007199254740991 {
		return refuse_typed(client, "attribution", "touch_time_ms is whole epoch milliseconds")
	}
	if a.touch_time_ms > 0 {
		props["rs_touch_time"] = json.Integer(a.touch_time_ms)
	}
	if !typed_track(client, len(a.name) > 0 ? a.name : "rs_attribution", props, nil) {
		return false
	}
	if len(flag) > 0 {
		_ = os.write_entire_file(flag, transmute([]u8)string("1"))
	}
	return true
}
