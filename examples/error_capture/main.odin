// Error capture sample: the one host line, a logged error, and a failed
// assertion that is sent on the next launch.
//
// It talks to a local API only (http://localhost:3000 unless you pass
// -define:RAVENSIGHT_API=...), and does nothing without a key:
//
//   odin run examples/error_capture -define:RAVENSIGHT_KEY=gt_live_dev_key
//   odin run examples/error_capture -define:RAVENSIGHT_KEY=gt_live_dev_key -- crash
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:time"
import rs "../../ravensight"

RAVENSIGHT_KEY :: #config(RAVENSIGHT_KEY, "")
RAVENSIGHT_API :: #config(RAVENSIGHT_API, "http://localhost:3000")

main :: proc() {
	// The game's own logger, as it was before Ravensight.
	context.logger = log.create_console_logger()

	client, _ := rs.create(rs.Config{
		ingest_key = RAVENSIGHT_KEY,
		api_url    = RAVENSIGHT_API,
		optional   = true,
		callbacks  = rs.Callbacks{
			on_log = proc(user: rawptr, level: rs.Log_Level, message: string) {
				log.info(message) // the SDK's own lines are never captured
			},
		},
	})

	// The one host line: capture .Error and .Fatal log lines and failed
	// assertions, chaining to the logger and assertion procedure above.
	context = rs.install_error_capture()

	log.info("level loaded")
	log.warn("texture missing: rock_07")
	log.error("save failed for slot 3")

	for _ in 0 ..< 60 {
		rs.tick(client)
		time.sleep(16 * time.Millisecond)
	}

	if len(os.args) > 1 && os.args[1] == "crash" {
		slot := 12
		assert(slot < 10, fmt.tprintf("slot %d out of range", slot))
	}

	rs.shutdown(client)
}
