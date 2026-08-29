# Ravensight for Odin

Official Odin SDK for [Ravensight](https://ravensight.io) player analytics.

Sessions, batched events, an offline queue, rate limit handling and a server
side kill switch, in one Odin package pumped from your main loop.

* API base: `https://api.ravensight.io/api/v1`
* Docs: https://ravensight.io/docs/
* Odin: a current release (tested against `dev-2026-08`)

## BETA notice

This package is a beta. The protocol logic in `core.odin` is written and
reviewed against the live API contract, is a pure state machine with no
network or clock access, and is covered by unit tests that drive every retry
path deterministically (`odin test ravensight`). The curl transport has been
exercised end to end against a local server, but the SDK has **not** yet
shipped inside a released game.

Treat it as pending in production verification: read the code before you ship
it in a release build, and please open an issue with anything you hit. The
JavaScript, Godot and Unity SDKs speak the same protocol.

## Install

Copy or submodule the `ravensight/` directory into your project, then import
it by relative path:

```odin
import rs "ravensight"
```

Or register it as a collection and import it from anywhere:

```
odin build src -collection:libs=libs
```

```odin
import rs "libs:ravensight"
```

### Linking libcurl

Odin's core library has no TLS, so HTTPS goes through the platform's libcurl
(via `foreign import`, no hand-rolled TLS). What that needs per platform:

| Platform | What to do |
| --- | --- |
| macOS | Nothing. The system libcurl ships with the OS and links via `-lcurl` automatically. |
| Linux | Install the dev package once: `sudo apt install libcurl4-openssl-dev` (or `curl-devel` on Fedora). Links via `-lcurl`. |
| Windows | Untested. Provide `libcurl.lib` plus the matching DLL, e.g. from `vcpkg install curl`, and make sure the import library is on the linker path (`-extra-linker-flags:"/LIBPATH:..."`). |

## Quickstart

```odin
package my_game

import rs "ravensight"

main :: proc() {
    analytics, err := rs.create(rs.Config{
        ingest_key = "gt_live_your_key",
    })
    if err != .None {
        // Missing key or curl unavailable; run without analytics.
    }

    for game_running {
        rs.tick(analytics) // non-blocking, call once per frame

        // ... your frame ...
    }

    rs.shutdown(analytics) // sends game_exited, one bounded final flush
}
```

Track from anywhere. `data` is any JSON-serializable value, typically a
struct literal:

```odin
Level_Cleared :: struct {
    level:   int,
    deaths:  int,
    seconds: f32,
}

rs.track(analytics, "level_completed", Level_Cleared{
    level   = level,
    deaths  = deaths,
    seconds = seconds,
})
```

## API

Everything game code needs, in package `ravensight`:

| Call | What it does |
| --- | --- |
| `create(config) -> (^Client, Error)` | Creates a client. `Config{ingest_key = "..."}` is a complete configuration. |
| `tick(client)` | Pumps the SDK. Call once per frame; never blocks. |
| `track(client, name, data)` | Queues an event. `data` is optional. Returns false when tracking is off. |
| `flush(client, force)` | Sends queued events on the next tick instead of waiting for the timer. `force` also skips an active backoff wait. |
| `submit_feedback(client, message, category, rating)` | Posts player feedback. Result arrives via callbacks. |
| `fetch_suggestions(client)` | EXPERIMENTAL. AI generated design suggestions for your game, via `on_suggestions`. |
| `set_enabled(client, bool)` | Local opt in and opt out for a privacy toggle. |
| `is_ready(client)` | True once a session exists. |
| `queue_len(client)`, `stats(client)` | Queue depth and lifetime counters. |
| `shutdown(client, flush_timeout_ms)` | Final best-effort flush, then frees everything. |

Results are delivered through optional callbacks in `Config.callbacks`
(`on_session_ready`, `on_events_flushed`, `on_feedback_submitted`,
`on_suggestions`, ...), invoked from inside `tick()` on your thread, so no
locking is ever needed in your handlers.

## Config

| Field | Default | Meaning |
| --- | --- | --- |
| `ingest_key` | none | Your publishable `gt_live_...` key. Required. |
| `api_url` | `https://api.ravensight.io/api/v1` | Only change this if you self host. `/api/v1` is appended when omitted. |
| `game_version` | `1.0.0` | Reported with every session. |
| `platform` | build target OS | Reported with every session. |
| `device_id` | random per run | Persist it yourself (save file) and pass it back to count returning players as returning. |
| `max_queue_size` | `500` | Offline queue cap. Oldest events are dropped first. |
| `flush_interval_ms` | `5000` | Queued events are flushed at least this often. Negative flushes only on demand. |
| `request_timeout_ms` | `15000` | Per request timeout. |
| `disable_lifecycle_events` | `false` | Set true to suppress the automatic `game_started` and `game_exited` events. |

## About your ingest key

The `gt_live_...` key is publishable. It is safe to ship inside a build: it
can only open sessions and read the tracking kill switch. It cannot read
analytics, read feedback or touch your account. Rotate it from the dashboard
at any time.

## How delivery works

* **Batching.** Up to 50 events per request, the server hard limit. Flushing
  keeps sending batches until the queue drains.
* **Offline queue.** Events accumulate up to `max_queue_size`. Past that the
  oldest are dropped so the newest are always kept.
* **Never dropped on failure.** Events leave the queue only after the server
  answers `202`.
* **Session expiry.** A `401` clears the session, opens a new one and re
  sends the same batch. Repeated `401`s on fresh tokens back off instead of
  hot-looping.
* **Rate limits.** A `429` honors `Retry-After` in seconds. With no such
  header the SDK backs off exponentially from 10 seconds to a 5 minute
  ceiling. The queue is held, never discarded.
* **Oversize batches.** A `400` halves the batch and retries down to a single
  event. An event still rejected on its own is dropped so it cannot block
  everything behind it.
* **Kill switch.** `GET /settings` is read once at boot. If the server has
  tracking off for your game, the queue is cleared and nothing is sent.

Flushes happen on the flush timer, whenever a full batch of 50 is waiting,
on `flush()` and on `shutdown()`. The shutdown flush is bounded by
`flush_timeout_ms` (default 2 seconds) and is best effort: anything not
delivered is gone, since the queue lives in memory only.

## Architecture

```
ravensight/
  core.odin        the whole protocol as a pure state machine: batching,
                   backoff, sessions, kill switch. No I/O, no clock reads;
                   time and network answers arrive as arguments, which is
                   what makes every retry path unit-testable.
  client.odin      the public API. Owns one Core plus one curl multi handle,
                   pumps both from tick(), serializes with core:encoding/json.
  curl.odin        minimal libcurl foreign binding (multi interface).
  core_test.odin   deterministic tests for every retry path (odin test).
```

**Why a tick pump instead of a background thread:** games already own a main
loop, and the curl multi interface makes every network step non-blocking, so
`tick()` can pump the whole SDK single-threaded. That means no thread
lifetime or shutdown hazards, no locks anywhere (in the SDK or in your
callbacks), and deterministic behavior under a debugger. The one deliberate
exception is `shutdown()`, which may block briefly (bounded by its timeout)
to get the last batch out, the same best-effort quit flush the other
Ravensight SDKs perform.

Run the tests:

```bash
odin test ravensight
```

## Device id and privacy

The SDK generates a random device id per run unless you pass one in. No
hardware identifier, advertising id, IP based fingerprint or personal data is
collected by the SDK itself. Only the events you choose to send leave the
machine. To count returning players as returning, store the id in your save
data and pass it back via `Config.device_id`.

`set_enabled(client, false)` stops all sending and discards anything still
queued, so an opt out does not leave player data sitting in memory.

## License

MIT. Copyright 2026 Reality Software Entertainment.
