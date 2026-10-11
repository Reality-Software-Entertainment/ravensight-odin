# Changelog

All notable changes to the Ravensight Odin SDK. Before 1.0, a minor version
may break the API.

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
