#+build darwin
package ravensight

import "core:c"
import "core:strings"

foreign import libc "system:System.framework"

@(default_calling_convention = "c")
foreign libc {
	setxattr :: proc(path: cstring, name: cstring, value: rawptr, size: c.size_t, position: u32, options: c.int) -> c.int ---
}

// The extended attribute `tmutil addexclusion` writes, and its value: the
// binary property list of the string "com.apple.backupd".
BACKUP_EXCLUDE_NAME :: "com.apple.metadata:com_apple_backup_excludeItem"
BACKUP_EXCLUDE_VALUE :: "bplist00_\x10\x11com.apple.backupd\x08\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1c"

// Keeps a file out of Time Machine backups. `done` is true when it was set;
// `supported` is false where there is no such call.
exclude_from_backup :: proc(path: string) -> (done: bool, supported: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	value := BACKUP_EXCLUDE_VALUE
	return setxattr(cpath, BACKUP_EXCLUDE_NAME, raw_data(value), c.size_t(len(value)), 0, 0) == 0, true
}
