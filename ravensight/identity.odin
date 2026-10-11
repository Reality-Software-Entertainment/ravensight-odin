// identity.odin - the saved device id and opt-out, and the playtest sources.
//
// The SDK keeps one small JSON file per game:
//
//   {"deviceId":"dev_<32 hex>","trackingEnabled":true}
//
// By default it lives at <user data dir>/ravensight/<executable name>/ravensight.json
// (macOS: ~/Library/Application Support, Windows: %APPDATA%, Linux:
// $XDG_DATA_HOME or ~/.local/share). Config.storage_path overrides it. A
// playtest run never reads or writes it.

package ravensight

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

STORAGE_FILE_NAME :: "ravensight.json"

ENV_PLAYTEST_TOKEN :: "RAVENSIGHT_PLAYTEST_TOKEN"
ENV_PLAYTEST_RUN_ID :: "RAVENSIGHT_PLAYTEST_RUN_ID"
ENV_PLAYTEST_JOB_ID :: "RAVENSIGHT_PLAYTEST_JOB_ID"
ENV_PLAYTEST_PERSONA :: "RAVENSIGHT_PLAYTEST_PERSONA"
ARG_PLAYTEST_TOKEN :: "--ravensight-playtest-token="
ARG_PLAYTEST_RUN_ID :: "--ravensight-playtest-run-id="

// The default storage file for this executable, or "" when the OS has no
// user data directory to offer. Allocated with `allocator`.
default_storage_path :: proc(allocator := context.allocator) -> string {
	data_dir, derr := os.user_data_dir(context.temp_allocator, roaming = true)
	if derr != nil || len(data_dir) == 0 {
		return ""
	}
	app := "game"
	if exe, eerr := os.get_executable_path(context.temp_allocator); eerr == nil && len(exe) > 0 {
		app = sanitize_app_name(os.stem(exe))
	}
	joined, jerr := os.join_path({data_dir, "ravensight", app, STORAGE_FILE_NAME}, allocator)
	if jerr != nil {
		return ""
	}
	return joined
}

// Keeps a folder name to ASCII letters, digits, '.', '_' and '-'.
@(private)
sanitize_app_name :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(name) {
		ch := name[i]
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
			strings.write_byte(&b, ch)
		case:
			strings.write_byte(&b, '_')
		}
	}
	out := strings.to_string(b)
	if len(out) == 0 || out == "." || out == ".." {
		return "game"
	}
	return out
}

Saved_Identity :: struct {
	device_id:        string, // "" when the file has none
	tracking_enabled: bool,   // true unless the player opted out
	// The file exists but could not be read or parsed. It may hold an
	// opt-out, so the caller must treat the player as opted out and must not
	// overwrite it on its own.
	unreadable:       bool,
}

// Reads the storage file. A missing file reads as no id and tracking on; an
// existing file that cannot be read or parsed sets `unreadable`.
// `device_id` is allocated with `allocator`.
load_identity :: proc(path: string, allocator := context.allocator) -> (saved: Saved_Identity) {
	saved.tracking_enabled = true
	if len(path) == 0 || !os.exists(path) {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		saved.unreadable = true
		return
	}
	parsed, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil {
		saved.unreadable = true
		return
	}
	obj, is_obj := parsed.(json.Object)
	if !is_obj {
		saved.unreadable = true
		return
	}
	if v, has := obj["deviceId"]; has {
		if s, is_str := v.(json.String); is_str && len(strings.trim_space(string(s))) > 0 {
			saved.device_id = strings.clone(strings.trim_space(string(s)), allocator)
		}
	}
	if v, has := obj["trackingEnabled"]; has {
		if b, is_bool := v.(json.Boolean); is_bool {
			saved.tracking_enabled = bool(b)
		}
	}
	return
}

// Writes the storage file synchronously, creating its folder. The write
// goes to a temporary file first and is renamed over the old one, so a
// crash mid-write cannot leave half a file. Returns false on any failure.
save_identity :: proc(path: string, saved: Saved_Identity) -> bool {
	if len(path) == 0 {
		return false
	}
	dir, _ := os.split_path(path)
	if len(dir) > 0 && !os.exists(dir) {
		if os.make_directory_all(dir) != nil {
			return false
		}
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	if len(saved.device_id) > 0 {
		strings.write_string(&b, `"deviceId":`)
		write_json_string(&b, saved.device_id)
		strings.write_byte(&b, ',')
	}
	strings.write_string(&b, `"trackingEnabled":`)
	strings.write_string(&b, saved.tracking_enabled ? "true" : "false")
	strings.write_byte(&b, '}')

	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, strings.to_string(b)) != nil {
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// Saves the player's analytics choice without a client, e.g. from a
// settings screen before create() or in a launcher. The saved device id is
// kept. `storage_path` "" means default_storage_path(). Returns false when
// the file could not be written.
write_tracking_enabled :: proc(enabled: bool, storage_path := "") -> bool {
	path := storage_path
	if len(path) == 0 {
		path = default_storage_path(context.temp_allocator)
	}
	// An explicit choice: it replaces even a file that could not be read.
	saved := load_identity(path, context.temp_allocator)
	saved.tracking_enabled = enabled
	return save_identity(path, saved)
}

// A new random device id: "dev_" plus 32 lowercase hex characters from 16
// bytes of the platform's cryptographic random source.
generate_device_id :: proc(allocator: runtime.Allocator) -> string {
	bytes: [16]u8
	crypto.rand_bytes(bytes[:])
	b := strings.builder_make(allocator)
	strings.write_string(&b, "dev_")
	for x in bytes {
		fmt.sbprintf(&b, "%02x", x)
	}
	return strings.to_string(b)
}

// A Ravensight Playtest run's identity. Strings are borrowed from wherever
// they were found.
Playtest_Context :: struct {
	token:   string,
	run_id:  string,
	job_id:  string,
	persona: string,
}

// Reads the four RAVENSIGHT_PLAYTEST_* variables into `allocator`.
read_playtest_env :: proc(allocator := context.allocator) -> Playtest_Context {
	return Playtest_Context{
		token   = os.get_env(ENV_PLAYTEST_TOKEN, allocator),
		run_id  = os.get_env(ENV_PLAYTEST_RUN_ID, allocator),
		job_id  = os.get_env(ENV_PLAYTEST_JOB_ID, allocator),
		persona = os.get_env(ENV_PLAYTEST_PERSONA, allocator),
	}
}

// Picks each field from the first source that has it: the explicit Config
// values, then the environment, then (token and run id only) the command
// line arguments --ravensight-playtest-token= and --ravensight-playtest-run-id=.
resolve_playtest :: proc(explicit: Playtest_Context, env: Playtest_Context, args: []string) -> (ctx: Playtest_Context) {
	pick :: proc(values: ..string) -> string {
		for v in values {
			t := strings.trim_space(v)
			if len(t) > 0 {
				return t
			}
		}
		return ""
	}
	arg_token, arg_run: string
	for a in args {
		if strings.has_prefix(a, ARG_PLAYTEST_TOKEN) {
			arg_token = a[len(ARG_PLAYTEST_TOKEN):]
		} else if strings.has_prefix(a, ARG_PLAYTEST_RUN_ID) {
			arg_run = a[len(ARG_PLAYTEST_RUN_ID):]
		}
	}
	ctx.token = pick(explicit.token, env.token, arg_token)
	ctx.run_id = pick(explicit.run_id, env.run_id, arg_run)
	ctx.job_id = pick(explicit.job_id, env.job_id)
	ctx.persona = pick(explicit.persona, env.persona)
	return
}
