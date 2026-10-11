# Ravensight for Odin

Official Odin SDK for [Ravensight](https://ravensight.io) player analytics.

Sessions, batched events, an offline queue, rate limit handling, a server
side kill switch and a saved player opt-out, in one Odin package pumped from
your main loop.

* API host: `https://api.ravensight.io` (the SDK appends `/api/v1`)
* Docs: https://ravensight.io/docs/
* Privacy: a random device id saved per install, no advertising identifier, a saved player opt-out (`set_tracking_enabled`), no tracking permission prompt needed. What your store label can say: https://ravensight.io/docs/#privacy-label
* Odin: tested with `dev-2026-08` (the release CI pins)

## Verification status

What has been run, on macOS with Odin `dev-2026-08:8412dc37a`:

* `odin test ravensight`: 58 tests pass. 33 drive the protocol state machine
  in `core.odin` with a fake clock; 25 drive the public API in `client.odin`
  through a fake transport and a real storage file in a temporary folder.
* `odin build examples/minimal` builds.
* The libcurl transport was run end to end against a local mock server:
  settings, session, batch and feedback requests, the playtest header from
  the command line, and the storage file.
* `odin check ravensight -no-entry-point` passes for `windows_amd64`,
  `linux_amd64` and `linux_arm64` targets (type checking only).

Not yet verified: running on Windows or Linux from this branch (CI runs the
tests on Ubuntu and macOS once the branch is in a pull request), and a
released game: the SDK has **not** yet shipped inside one. Read the code before you ship it in a release build, and please open
an issue with anything you hit.

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
        // Missing key or libcurl unavailable. Stop here, or carry on:
        // every rs call accepts a nil client and does nothing.
        return
    }

    for game_running {
        rs.tick(analytics) // non-blocking, call once per frame

        // ... your frame ...
    }

    rs.shutdown(analytics) // queues game_exited, holds the quit at most 1.5 s
}
```

Track from anywhere. `data` is any JSON-serializable value, typically a
struct literal. `track` only queues; sending happens from `tick()`.

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

## Levels and deaths

The level funnel, per-level deaths and journeys read your event names with
no configuration: names containing `died`, `destroyed` or `killed` are
deaths, names containing `start`, `begin` or `enter` are level starts, and
names containing `complet`, `finish`, `win` or `clear` are completions. The
`level`, `location` or `track` field names the place.

To say it explicitly, set `rs_kind` in the event data to `level_start`,
`level_complete`, `death` or `none`. It is read before the name, and `none`
opts an event out, so `checkout_started` is not a level start. An unknown
value falls back to the name. Keys that start with `rs_` are reserved for
Ravensight.

```odin
Boss_Phase :: struct {
    level:   string,
    rs_kind: string,
}

rs.track(analytics, "boss_phase_begin", Boss_Phase{level = "castle", rs_kind = "none"})
rs.track(analytics, "run_over", Boss_Phase{level = "castle", rs_kind = "death"})
```

## Feedback

```odin
rs.submit_feedback(analytics, "Jump feels floaty on level 3", category = "bug", rating = 4)
```

`category` is `""` or one of `rs.FEEDBACK_CATEGORIES`: `bug`, `suggestion`,
`complaint`, `praise`, `playtest`, `other`. `rating` is `0` (left out) or a
whole number from 1 to 5. Anything else fails at once through
`on_feedback_failed` with `invalid_category` or `invalid_rating`, and no
request is made. Feedback sent before a session exists waits for one (up to
5 messages) and goes out as soon as it opens.

## API

Everything game code needs, in package `ravensight`. Every call accepts a nil
client and does nothing.

| Call | What it does |
| --- | --- |
| `create(config) -> (^Client, Error)` | Creates a client. `Config{ingest_key = "..."}` is a complete configuration. Reads the saved device id and opt-out, and queues `game_started`. |
| `tick(client)` | Pumps the SDK. Call once per frame; never blocks. |
| `track(client, name, data)` | Queues an event. `data` is optional. Returns false when tracking is off. |
| `flush(client, force)` | Sends queued events on the next tick instead of waiting for the timer. `force` also skips an active backoff wait. After a refused key it allows one more attempt. |
| `submit_feedback(client, message, category, rating)` | Posts player feedback. Result arrives via callbacks. |
| `fetch_suggestions(client)` | EXPERIMENTAL. AI generated design suggestions for your game, via `on_suggestions`. While not active it makes no request and answers `"[]"`. |
| `set_tracking_enabled(client, bool)` | The player's choice, saved and read again on every launch. |
| `write_tracking_enabled(bool, storage_path)` | The same, before a client exists. |
| `is_tracking_enabled(client)` | False after the player opted out, on this run or an earlier one. |
| `reset_device_id(client) -> string` | A new saved random id, an empty queue and no session. Returns the new id. |
| `set_enabled(client, bool)` | Turns sending off and on for this run only, like `Config.start_disabled`. Not saved. |
| `init_reason(client) -> Reason` | Why the client is not sending, or `.None`. `reason_string` gives the text form. |
| `session_token(client) -> string` | The current session token, `""` until a session opens. |
| `device_id(client)`, `is_playtest(client)` | The id this run sends, and whether a playtest token was found. |
| `is_ready(client)`, `is_active(client)` | A session exists; tracking is on. |
| `queue_len(client)`, `stats(client)` | Queue depth and lifetime counters (`sent`, `dropped`, `flushes`, `sessions`). |
| `shutdown(client, flush_timeout_ms)` | Queues `game_exited`, one best-effort flush, then frees everything. |

Results are delivered through optional callbacks in `Config.callbacks`
(`on_session_ready`, `on_events_flushed`, `on_feedback_submitted`,
`on_suggestions`, `on_reason_changed`, `on_log`, ...), invoked on your
thread from inside `tick()` or the call that caused them, so no locking is
ever needed in your handlers. `on_log` gets a level and a message that
starts with `Ravensight: `; without a handler, warnings go to stderr.

## Config

| Field | Default | Meaning |
| --- | --- | --- |
| `ingest_key` | none | Your publishable `gt_live_...` key. Required. |
| `api_url` | `https://api.ravensight.io` | Only change this if you self host. With or without `/api/v1` and trailing slashes. |
| `game_version` | `1.0.0` | Reported with every session. |
| `platform` | build target OS | Reported with every session. |
| `device_id` | the saved id | Overrides the saved id for this run. The saved file is not changed. |
| `storage_path` | see "Device id and privacy" | The file holding the device id and the player's opt-out. |
| `start_disabled` | `false` | Send nothing, not even the settings check, until `set_enabled(client, true)`. Not saved. |
| `max_queue_size` | `500` | Offline queue cap. Oldest events are dropped first. |
| `flush_interval_ms` | `5000` | Queued events are flushed at least this often. Negative flushes only on demand. |
| `request_timeout_ms` | `15000` | Per request timeout. |
| `disable_lifecycle_events` | `false` | Set true to suppress the automatic `game_started` and `game_exited` events. |
| `playtest_token`, `playtest_run_id`, `playtest_job_id`, `playtest_persona` | `""` | Ravensight Playtest. Normally left empty; see "Playtest". |

## Automatic events

Exactly two:

* `game_started`, queued by `create()` with that moment's timestamp, so it
  is first in the queue, then sent once the settings check says tracking is
  on. Once per run: a client created disabled or opted out queues it when
  it is first enabled, and never twice.
* `game_exited`, queued once by `shutdown()`, followed by one best-effort
  flush that holds the quit for at most 1.5 seconds (`flush_timeout_ms`).

There are no pause or resume events. This SDK targets desktop builds; call
`shutdown()` on your quit path. A window losing focus is not an exit and
sends nothing. The mobile background rule of the other SDKs does not apply.

## When it stops sending

`init_reason(client)` says why, and `on_reason_changed` reports every
change:

| Reason | When | What happens |
| --- | --- | --- |
| `.None` | Ready, or nothing has gone wrong yet. | |
| `.Disabled` | `start_disabled`, `set_enabled(false)` or the player's opt-out. | No request of any kind. |
| `.Invalid_Key` | A `401`, or a `403` without one of the codes below, from settings, session or suggestions. | Automatic sending stops for the run; events keep queueing (the cap applies); `flush()` makes one more attempt. Logged once as a warning. |
| `.Tracking_Disabled` | The game's tracking is switched off in the dashboard (`GET /settings`, or a `403 tracking_disabled` from any request). | The queue is cleared and nothing more is sent this run. |
| `.Offline` | No answer, a timeout or a server error. | Retried after 10 seconds, doubling to 5 minutes. |
| `.Rate_Limited` | A `429`. | Retried after exactly `Retry-After` seconds. |
| `.Session_Failed` | `POST /session` failed, or a playtest token is unusable. | Retried, except for a playtest token, which stops the run. |
| `.Playtest_Job_Closed` | The playtest run's job closed. | The queue is cleared and nothing more is sent this run. |

## About your ingest key

The `gt_live_...` key is publishable. It is safe to ship inside a build: it
can open sessions, read the tracking kill switch and read this game's design
suggestions. It cannot read analytics, read feedback or touch your account.
Rotate it from the dashboard at any time.

## How delivery works

* **Batching.** Up to 50 events per request, the server hard limit. A send
  happens on the flush timer, at once when 50 are waiting, on `flush()` and
  on `shutdown()`, and keeps going until the queue drains.
* **Offline queue.** Events accumulate up to `max_queue_size`. Past that the
  oldest are dropped so the newest are always kept. The queue lives in
  memory only.
* **When events are dropped.** Events leave the queue when the server
  accepts them (`202`), on overflow (oldest first), when the server rejects a
  single event, on opt-out, on `reset_device_id`, on the kill switch, when a
  playtest run closes, and when `shutdown()` runs out of time.
* **Session expiry.** A `401` on a batch clears the session, opens a new one
  and re-sends the same batch. After two in a row it backs off instead of
  hot-looping.
* **Rate limits.** A `429` honors `Retry-After` in seconds, and so does a
  `503`. With no such header the SDK backs off from 10 seconds to a 5 minute
  ceiling. The queue is held.
* **Oversize batches.** A `400` halves the batch and retries down to a single
  event. An event still rejected on its own is dropped (counted in
  `stats().dropped`, logged once) so it cannot block everything behind it.
* **Kill switch.** `GET /settings` is read once at boot, before anything
  else is sent.

## Device id and privacy

On first launch the SDK generates a random device id, `dev_` plus 32
lowercase hex characters from the platform's cryptographic random source,
and saves it, so a returning player counts as returning. It is not derived
from hardware or an account. No advertising id, IP based fingerprint or
personal data is collected by the SDK itself; only the events you choose to
send leave the machine.

The id and the player's choice live in one small JSON file,
`{"deviceId": "...", "trackingEnabled": true}`, at
`<user data folder>/ravensight/<executable name>/ravensight.json`:

| OS | User data folder |
| --- | --- |
| macOS | `~/Library/Application Support` |
| Windows | `%APPDATA%` |
| Linux | `$XDG_DATA_HOME`, or `~/.local/share` |

The folder includes the executable name, so an executable whose name
changes between versions (for example `mygame-1.2`) starts a new identity
and a new opt-out; give it a stable name or set `Config.storage_path`. If
the file exists but cannot be read, the SDK treats the player as opted out
for that run and leaves the file untouched.

Set `Config.storage_path` to keep it inside your own save folder instead.
Pass the same path to `write_tracking_enabled` if you call it from another
program, such as a launcher.

```odin
// The player's analytics switch, saved and honoured on every launch.
rs.set_tracking_enabled(analytics, false) // clears the queue, sends nothing
rs.set_tracking_enabled(analytics, true)

// "Forget me": a fresh random identity from now on.
new_id := rs.reset_device_id(analytics)
```

A saved opt-out wins over the config: the next launch sends nothing, not
even the settings check. Existing saved ids are never rewritten.

A game that sends gameplay events and nothing else can declare Device ID and
Product Interaction as not linked to the player and not used for tracking,
and needs no tracking permission prompt. The row by row answers for the App
Store and Google Play forms are at https://ravensight.io/docs/#privacy-label.

## Telling players

You do not need a permission prompt, but saying what the game sends is good
manners. A paragraph your game can show, in a settings screen or on its
store page:

> This game sends anonymous gameplay events (what happens in the game, never
> who you are) to Ravensight so we can improve it. You can turn this off in
> Settings at any time.

And the toggle behind "turn this off":

```odin
// an "Analytics" switch in your settings screen
set_analytics :: proc(analytics: ^rs.Client, on: bool) {
    rs.set_tracking_enabled(analytics, on) // remembered across launches
}

// a "Forget me" button: a fresh random identity from now on
forget_me :: proc(analytics: ^rs.Client) {
    rs.reset_device_id(analytics)
}
```

## Playtest

When Ravensight Playtest runs your build, it passes a token and a run id.
The SDK looks for them in this order, first found wins: the `playtest_*`
fields in `Config`, the environment variables `RAVENSIGHT_PLAYTEST_TOKEN`
and `RAVENSIGHT_PLAYTEST_RUN_ID` (plus `RAVENSIGHT_PLAYTEST_JOB_ID` and
`RAVENSIGHT_PLAYTEST_PERSONA` for tags), then the command line arguments
`--ravensight-playtest-token=` and `--ravensight-playtest-run-id=`.

With a token:

* the device id is `pt-<runId>`, in memory only; the storage file is never
  read or written, and the saved opt-out does not apply
* every request carries `X-Ravensight-Playtest: <token>`
* every event carries `synthetic`, `pt_run`, `pt_job`, `persona` and
  `pt_source` in its data, so persona sessions never mix with real players
* `set_tracking_enabled` and `reset_device_id` do nothing but log one line
* a token without a run id sends nothing at all (`.Session_Failed`)
* when the run's job closes (`403 playtest_job_closed`), the client stops
  for the rest of the run (`.Playtest_Job_Closed`)

`is_playtest(client)` says whether a token was found.

## Joining a session from a game server

`session_token(client)` returns the current session token, or `""` until a
session opens. A game server can pass it as `joinToken` to report into the
same player session. The SDK never computes a session id itself.

## Architecture

```
ravensight/
  core.odin         the whole protocol as a pure state machine: batching,
                    backoff, sessions, kill switch, refusals. No I/O, no
                    clock reads; time and network answers arrive as
                    arguments, which is what makes every retry path
                    unit-testable.
  client.odin       the public API. Owns one Core plus one curl multi handle,
                    pumps both from tick(), serializes with core:encoding/json.
  identity.odin     the storage file, the device id and the playtest sources.
  curl.odin         minimal libcurl foreign binding (multi interface).
  core_test.odin    deterministic tests for every retry path.
  client_test.odin  the public API through a fake transport.
```

**Why a tick pump instead of a background thread:** games already own a main
loop, and the curl multi interface makes every network step non-blocking, so
`tick()` can pump the whole SDK single-threaded. That means no thread
lifetime or shutdown hazards, no locks anywhere (in the SDK or in your
callbacks), and deterministic behavior under a debugger. The one deliberate
exception is `shutdown()`, which may block briefly (at most its timeout) to
get the last batch out.

## Running the tests

```bash
odin test ravensight          # 58 tests, no network, no engine
odin build examples/minimal   # the example compiles and links libcurl
```

The client tests use a fake transport and write their storage files to a
fresh folder under the system temporary directory, removed afterwards. On
Linux, install `libcurl4-openssl-dev` first. CI runs both commands on Ubuntu
and macOS with Odin `dev-2026-08`.

## License

MIT. Copyright 2026 Reality Software Entertainment.
