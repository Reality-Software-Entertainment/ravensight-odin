#+build windows
package ravensight

// Odin ships no zlib library for Windows, so request bodies go uncompressed
// there. The server accepts both.
gzip_compress :: proc(text: string, allocator := context.allocator) -> (out: string, ok: bool) {
	return "", false
}
