#+build darwin
package ravensight

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

foreign import libc_test "system:System.framework"

@(default_calling_convention = "c")
foreign libc_test {
	getxattr :: proc(path: cstring, name: cstring, value: rawptr, size: c.size_t, position: u32, options: c.int) -> int ---
}

@(test)
test_queue_file_excluded_from_time_machine :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	boot_with(t, &f, cl, session_json(ORIGIN_A))
	track(cl, "kept")
	tick(cl)
	path := queue_file_of(&f)
	testing.expect(t, os.exists(path))
	buf: [128]u8
	n := getxattr(strings.clone_to_cstring(path, context.temp_allocator), BACKUP_EXCLUDE_NAME, &buf[0], len(buf), 0, 0)
	testing.expect_value(t, string(buf[:max(n, 0)]), BACKUP_EXCLUDE_VALUE)
	_ = fmt.tprint("")
}

@(test)
test_existing_queue_file_excluded_on_load :: proc(t: ^testing.T) {
	f: Fake
	fake_init(&f)
	defer fake_destroy(&f)
	os.make_directory_all(f.dir)
	path := queue_file_of(&f)
	text := `{"version":2,"groups":[{"events":[{"event":"old","timestamp":900000,"data":{}}]}]}`
	_ = os.write_entire_file(path, transmute([]u8)text)
	buf: [128]u8
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	testing.expect(t, getxattr(cpath, BACKUP_EXCLUDE_NAME, &buf[0], len(buf), 0, 0) < 0, "not excluded before")
	cl := fake_client(t, &f, Config{})
	defer close_client(cl)
	n := getxattr(cpath, BACKUP_EXCLUDE_NAME, &buf[0], len(buf), 0, 0)
	testing.expect_value(t, string(buf[:max(n, 0)]), BACKUP_EXCLUDE_VALUE)
}
