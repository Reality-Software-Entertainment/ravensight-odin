// Minimal Ravensight integration: create, tick from the main loop, shutdown.
package main

import "core:fmt"
import "core:time"
import rs "../../ravensight"

main :: proc() {
	client, err := rs.create(rs.Config{
		ingest_key = "gt_live_your_ingest_key_here",
		callbacks = rs.Callbacks{
			on_log = proc(user: rawptr, message: string) {
				fmt.println("[ravensight]", message)
			},
		},
	})
	if err != .None {
		fmt.println("ravensight disabled:", err)
		return
	}

	Level_Cleared :: struct {
		level:   int,
		deaths:  int,
		seconds: f32,
	}
	rs.track(client, "level_completed", Level_Cleared{level = 3, deaths = 2, seconds = 71.4})

	// Your game loop. tick() is non-blocking; call it once per frame.
	for _ in 0 ..< 120 {
		rs.tick(client)
		time.sleep(16 * time.Millisecond)
	}

	// Sends game_exited and performs one bounded final flush.
	rs.shutdown(client)
}
