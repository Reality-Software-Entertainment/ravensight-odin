// curl.odin - minimal libcurl binding, just the surface this SDK needs.
//
// Odin's core:net has no TLS, so HTTPS goes through the platform's libcurl
// (the curl multi interface, pumped from tick(), so nothing here blocks).
// TLS itself is never hand-rolled; libcurl uses the OS certificate store.
//
// Option and info constants are the stable numeric values from curl.h;
// libcurl's ABI guarantees they never change.

package ravensight

import "core:c"

when ODIN_OS == .Windows {
	foreign import libcurl "system:libcurl.lib"
} else {
	foreign import libcurl "system:curl"
}

CURL :: distinct rawptr
CURLM :: distinct rawptr

Curl_Slist :: struct {
	data: cstring,
	next: ^Curl_Slist,
}

Curl_Msg :: struct {
	msg:         c.int, // CURLMSG_DONE when a transfer finished
	easy_handle: CURL,
	data:        struct #raw_union {
		whatever: rawptr,
		result:   c.int, // CURLcode for the finished transfer
	},
}

CURLE_OK :: 0
CURLMSG_DONE :: 1
CURL_GLOBAL_DEFAULT :: 3 // CURL_GLOBAL_SSL | CURL_GLOBAL_WIN32

// CURLOPTTYPE_LONG = 0, OBJECTPOINT/STRINGPOINT/SLISTPOINT/CBPOINT = 10000,
// FUNCTIONPOINT = 20000 (see curl.h).
CURLOPT_WRITEDATA :: 10001
CURLOPT_URL :: 10002
CURLOPT_USERAGENT :: 10018
CURLOPT_HTTPHEADER :: 10023
CURLOPT_POST :: 47
CURLOPT_HTTPGET :: 80
CURLOPT_NOSIGNAL :: 99
CURLOPT_TIMEOUT_MS :: 155
CURLOPT_CONNECTTIMEOUT_MS :: 156
CURLOPT_COPYPOSTFIELDS :: 10165
CURLOPT_WRITEFUNCTION :: 20011

CURLINFO_RESPONSE_CODE :: 0x200000 + 2  // long
CURLINFO_RETRY_AFTER :: 0x600000 + 57   // curl_off_t, Retry-After in seconds

Curl_Write_Proc :: proc "c" (ptr: [^]u8, size: c.size_t, nmemb: c.size_t, user: rawptr) -> c.size_t

@(default_calling_convention = "c")
foreign libcurl {
	curl_global_init :: proc(flags: c.long) -> c.int ---
	curl_global_cleanup :: proc() ---

	curl_easy_init :: proc() -> CURL ---
	curl_easy_cleanup :: proc(handle: CURL) ---

	// C varargs, exactly as declared in curl.h. Always pass the value with
	// an explicit C-compatible type (c.long, cstring, rawptr, a pointer);
	// the typed wrappers below keep call sites honest.
	curl_easy_setopt :: proc(handle: CURL, option: c.int, #c_vararg args: ..any) -> c.int ---
	curl_easy_getinfo :: proc(handle: CURL, info: c.int, #c_vararg args: ..any) -> c.int ---

	curl_slist_append :: proc(list: ^Curl_Slist, str: cstring) -> ^Curl_Slist ---
	curl_slist_free_all :: proc(list: ^Curl_Slist) ---

	curl_multi_init :: proc() -> CURLM ---
	curl_multi_cleanup :: proc(multi: CURLM) -> c.int ---
	curl_multi_add_handle :: proc(multi: CURLM, easy: CURL) -> c.int ---
	curl_multi_remove_handle :: proc(multi: CURLM, easy: CURL) -> c.int ---
	curl_multi_perform :: proc(multi: CURLM, running_handles: ^c.int) -> c.int ---
	curl_multi_info_read :: proc(multi: CURLM, msgs_in_queue: ^c.int) -> ^Curl_Msg ---
	curl_multi_wait :: proc(multi: CURLM, extra_fds: rawptr, extra_nfds: c.uint, timeout_ms: c.int, ret: ^c.int) -> c.int ---
}

// Typed wrappers so every setopt/getinfo call site states its C type.

curl_setopt_long :: proc "c" (handle: CURL, option: c.int, value: c.long) -> c.int {
	return curl_easy_setopt(handle, option, value)
}

curl_setopt_ptr :: proc "c" (handle: CURL, option: c.int, value: rawptr) -> c.int {
	return curl_easy_setopt(handle, option, value)
}

curl_setopt_str :: proc "c" (handle: CURL, option: c.int, value: cstring) -> c.int {
	return curl_easy_setopt(handle, option, value)
}

curl_setopt_slist :: proc "c" (handle: CURL, option: c.int, value: ^Curl_Slist) -> c.int {
	return curl_easy_setopt(handle, option, value)
}

curl_setopt_write_proc :: proc "c" (handle: CURL, option: c.int, value: Curl_Write_Proc) -> c.int {
	return curl_easy_setopt(handle, option, value)
}

curl_getinfo_long :: proc "c" (handle: CURL, info: c.int, out: ^c.long) -> c.int {
	return curl_easy_getinfo(handle, info, out)
}

curl_getinfo_off_t :: proc "c" (handle: CURL, info: c.int, out: ^i64) -> c.int {
	return curl_easy_getinfo(handle, info, out)
}
