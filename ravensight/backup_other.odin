#+build !darwin
package ravensight

// Windows and Linux have no common way to keep a file out of backups.
exclude_from_backup :: proc(path: string) -> (done: bool, supported: bool) {
	return false, false
}
