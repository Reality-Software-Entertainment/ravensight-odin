# Held combined release, October 17, 2026

Public-build support and typed events have been combined locally. This record
is verification evidence, not a publication or deployment record.

Validated: 90 tests on Odin dev-2026-08, macOS arm64.

Remote config 0.3.1: `odin test ravensight` passes with memory tracking and no
leak warnings. `odin check ravensight -no-entry-point` and
`odin build examples/minimal -out:/tmp/ravensight-odin-minimal` pass.
The fake transport verifies fetch headers, URL escaping, 200/304 handling,
offline persistence, scope isolation, typed fallbacks, bounds, callback delivery,
consent and reset races, playtest isolation and event exposure snapshots.
These checks do not claim live service connectivity.

The merge preserves public-key consent and inert-without-key behavior,
stable event IDs, typed event helpers and opt-in performance sampling.
JavaScript now defers performance listeners until consent; Android health
summaries carry the same deduplication IDs as other events.

Physical-device and live-service validation is not implied by these checks.
Publishing, tags, marketplace submission and deployments remain held pending
owner approval. Older README test counts describe their earlier branch runs;
this file records the combined candidate.
