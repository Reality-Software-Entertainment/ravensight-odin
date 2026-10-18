# Changelog

All notable changes to the Ravensight Odin SDK. Before 1.0, a minor version
may break the API.

## [0.3.1] - Unreleased (held)

- Fetch remote config on session start with scoped disk caching, ETag revalidation
  and offline fallback. Add typed getters, owned JSON copies and config-ready callbacks.
- Attach validated experiment assignments only to newly queued events.
- Preserve consent, playtest isolation, identity reset and stale-response protection.
- Validate payload limits before accepting config; cap curl response accumulation.
- Verified 90 Odin tests, package check and the minimal example build locally.
  No publication, tags or deployment has occurred.

## [0.3.0] - 2026-10-16

For games whose builds or source anyone can download. A game that sets a
key and none of the new options behaves as on 0.2.0, except for the
changes listed under Breaking. `VERSION` is `"0.3.0"`.

### Breaking

- `create()` with an empty `ingest_key` returns an inert client and
  `.None` instead of `nil, .Missing_Ingest_Key` (the enum value stays, and
  is no longer returned).
- A refused ingest key (`401`, or a `403` that is not the kill switch or a
  refused playtest token) from settings, session, a batch, feedback or
  suggestions now ends the run: the queue is cleared, nothing is retried,
  `track` returns false and `flush()` sends nothing. Before, events kept
  queueing and `flush()` allowed one more attempt. A `401` on a batch still
  means an expired session: a new one is opened first.
  `core_allow_one_attempt` is gone.
- Backoff waits carry plus or minus 20 percent jitter from `core:crypto`.
  `Retry-After` is still obeyed exactly. A bare `Core` (no `random` set)
  has no jitter.
- Every event's data gains an `rs_event_id` key.
- An event whose data is over 8,192 bytes as JSON is dropped before it is
  queued: `track` returns false, `on_flush_failed("event_too_large")`, one
  warning for the run. Before, it was sent and refused by the server's 400.

### Added

- **Inert without a key.** No libcurl, no file, no request, every call a
  quiet no-op; `Reason.No_Key` (`"no_key"`), one warning silenced by
  `Config.optional`.
- `Config.consent`: `.Opt_In` makes no device id and sends nothing, not
  even the settings check, before `set_tracking_enabled(client, true)`;
  the yes is saved in the storage file as `"optIn":true`. `.Opt_Out` stays
  the default. Events tracked before the yes are dropped; events right
  after it are queued while the settings check runs. Saying no again keeps
  the device id; `reset_device_id` forgets it and returns `""`.
  `write_tracking_enabled` takes the consent mode.
- `Config.distribution`, sent on `POST /session` when set (trimmed, at most
  40 UTF-16 units, no control characters; anything else is not sent and
  logs one warning).
- `rs_event_id` on every event whose data is a JSON object: the first 16
  characters of the device id, the start time in hex, an 8 hex character
  per-client nonce from `core:crypto` and a counter. It is part of the
  queued data, so a resend after a failure carries the same id.
- `is_enabled(client)`, `BACKOFF_JITTER`, `MAX_EVENT_BYTES`,
  `MAX_DISTRIBUTION_LENGTH`, `random_hex` and `random_unit`.

### Typed events and performance sampling (included in this release)

### Added

- Typed event helpers `track_purchase`, `track_resource`, `track_progression`
  and `track_error`. Each sets the reserved `rs_*` properties and calls
  `track`, takes optional `extra` properties (reserved keys win) and an
  optional event `name`, and returns what `track` returns.
- Opt-in health sampling, `Config.performance`. `tick(client, dt)` samples one
  frame per second (at most 600 samples), and `shutdown` sends a single
  `health` event with the median and 10th percentile frames per second and the
  boot time. `tick(client)` without `dt` still works.
- The session request carries `"sdk": "odin/<version>"`.

## [0.2.0] - 2026-10-10

### Breaking

- The device id is saved per install by default, in
  `<user data folder>/ravensight/<executable name>/ravensight.json`
  (`Config.storage_path` overrides it). It used to be new on every run unless
  you passed `Config.device_id`, which still overrides it.
- `set_enabled` is no longer the player's opt-out. It is the runtime switch,
  not saved, matching the new `Config.start_disabled`. Use
  `set_tracking_enabled` for the player's choice.
- `Callbacks.on_log` takes a `Log_Level`: `proc(user: rawptr, level: Log_Level, message: string)`.
  Messages start with `Ravensight: `. Without a handler, warnings go to stderr.
- `DEFAULT_API_URL` is the bare host `https://api.ravensight.io`; the SDK
  appends `/api/v1`.
- `game_started` is queued by `create()` with that timestamp, first in the
  queue, instead of after the settings answer.
- `shutdown()` holds the quit for at most 1.5 seconds by default (was 2).
- Feedback refused because tracking is off fails with `disabled` (was
  `tracking_disabled`). Feedback sent before a session no longer fails with
  `no_session`; it waits for the session.
- `on_session_failed` reasons use the shared vocabulary (`invalid_key`,
  `offline`, `rate_limited`, `session_failed`, `tracking_disabled`,
  `playtest_job_closed`) instead of the server's error text.

### Added

- `set_tracking_enabled(client, bool)`, saved synchronously and read on every
  launch; a saved opt-out wins over the config. `write_tracking_enabled` saves
  it before a client exists. `is_tracking_enabled`.
- `reset_device_id(client) -> string`: a new saved id, an empty queue, no
  session.
- `Config.start_disabled` and `Config.storage_path`.
- `init_reason(client) -> Reason`, `reason_string`, and
  `Callbacks.on_reason_changed`.
- `session_token(client)`, for a game server's `joinToken`.
- Ravensight Playtest: `Config.playtest_*`, the `RAVENSIGHT_PLAYTEST_*`
  environment variables and the `--ravensight-playtest-token=` /
  `--ravensight-playtest-run-id=` arguments; `pt-<runId>` in memory, the
  `X-Ravensight-Playtest` header on every request, synthetic tags on every
  event, `is_playtest(client)`.
- `FEEDBACK_CATEGORIES` and local feedback validation (`invalid_category`,
  `invalid_rating`); up to 5 feedback messages wait for a session.
- `device_id(client)`.
- Client tests through a fake transport (25), alongside the core tests (33).

### Fixed

- `fetch_suggestions` sent a request while the player had opted out or the
  kill switch was on. It now answers `"[]"` with no request.
- A refused ingest key (`401`) was retried forever and logged as "assuming
  tracking enabled". It now stops automatic sending for the run, keeps the
  queue, allows one attempt per `flush()`, and logs one warning.
- A `403 tracking_disabled` from `POST /session` was retried every few
  minutes. Any request answering it now switches tracking off for the run.
- `Retry-After` is honoured on `503` as well as `429`.
- Events tracked before the first `tick()` could precede `game_started`.
- Every public call is a no-op on a nil client, so the quickstart no longer
  dereferences nil when `create` fails.
- An answer to a request sent before an opt-out, a reset or the kill switch
  no longer removes events queued afterwards.
- `shutdown()` with nothing queued makes no request.
- Feedback waiting for a session is still sent when the first session
  attempt fails and a later one succeeds.
- A storage file that exists but cannot be read is kept, and the player is
  treated as opted out for that run, instead of being overwritten.
