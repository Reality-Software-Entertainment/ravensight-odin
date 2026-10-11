// Minimal Ravensight integration: create, tick from the main loop, shutdown.
package main

import "core:fmt"
import "core:time"
import rs "../../ravensight"

main :: proc() {
	client, err := rs.create(rs.Config{
		ingest_key = "gt_live_your_ingest_key_here",
		callbacks = rs.Callbacks{
			on_log = proc(user: rawptr, level: rs.Log_Level, message: string) {
				fmt.println(message)
			},
			on_reason_changed = proc(user: rawptr, reason: rs.Reason) {
				fmt.println("analytics state:", rs.reason_string(reason))
			},
		},
	})
	if err != .None {
		// Missing key or libcurl unavailable: run the game without analytics.
		fmt.println("ravensight disabled:", err)
		return
	}

	Level_Cleared :: struct {
		level:   int,
		deaths:  int,
		seconds: f32,
	}
	rs.track(client, "level_completed", Level_Cleared{level = 3, deaths = 2, seconds = 71.4})
	rs.submit_feedback(client, "Jump feels floaty on level 3", category = "bug", rating = 4)

	// Your game loop. tick() is non-blocking; call it once per frame.
	for _ in 0 ..< 120 {
		rs.tick(client)
		time.sleep(16 * time.Millisecond)
	}

	// Queues game_exited and holds the quit for at most 1.5 seconds to send it.
	rs.shutdown(client)
}
