#+build !windows
package ravensight

import "vendor:zlib"

// The gzip stream of `text`, or ok = false. Linked against the system zlib.
gzip_compress :: proc(text: string, allocator := context.allocator) -> (out: string, ok: bool) {
	strm: zlib.z_stream
	// windowBits 15 + 16 writes a gzip header and trailer.
	if zlib.deflateInit2(&strm, zlib.DEFAULT_COMPRESSION, zlib.DEFLATED, 15 + 16, 8, zlib.DEFAULT_STRATEGY) != zlib.OK {
		return "", false
	}
	defer zlib.deflateEnd(&strm)
	bound := int(zlib.deflateBound(&strm, zlib.uLong(len(text)))) + 32
	buf := make([]u8, bound, allocator)
	strm.next_in = raw_data(transmute([]u8)text)
	strm.avail_in = zlib.uInt(len(text))
	strm.next_out = raw_data(buf)
	strm.avail_out = zlib.uInt(bound)
	if zlib.deflate(&strm, zlib.FINISH) != zlib.STREAM_END {
		delete(buf, allocator)
		return "", false
	}
	return string(buf[:strm.total_out]), true
}
