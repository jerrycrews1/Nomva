# Nomva Re-Test & Error Report — August 1, 2026

> **FIX STATUS (updated same day):** Errors 1, 2, 3, 4, 5 (partial), 6, and 7 are now fixed in this working tree and verified — see `reports/retest-2026-08-01/post-fix-verification.txt`. Highlights: an empty AI completion on food resolution now returns a real database-backed food via deterministic fallback (HTTP 200) instead of failing; other endpoints retry once then return a distinguishable 503; all model-provided numbers are bounded server-side with a trap-safe `safeInt` backstop client-side; the server enforces its own 12s resolution deadline, aborts upstream work when the phone disconnects, and refuses a stale food database at boot; `deploy.sh` now gates on unit tests, DB checksum, remote DB schema, and post-deploy health. Unit tests: 49/49 (11 new regression tests). Source-check personas: 21/21. Error 6 turned out to be a stale test pattern — the coach CSV already had a populated "Water (oz)" column; the harness now asserts the real column. Error 5 (event-loop serialization) is mitigated by the deadline + parallel client resolution; the worker-thread refactor remains post-launch work. Final gate: run the live 100-persona suite against production after deploying.

## What was run

This re-test covered four layers. First, the full server unit suite (38 tests). Second, the 100-user power-test harness re-run against a locally booted copy of the production server code, backed by a scripted mock AI so failure modes could be injected deterministically — including the exact case you reported, where the AI returns no result. Third, fault-injection probes against every LLM-backed endpoint (empty completions, missing choices, null content, non-JSON text, upstream 500s, oversized numeric outputs, and 6-way concurrent load). Fourth, a source-level re-verification of all July persona failures against the current Swift code. The deployed server at nomva.nerdquad.com was not reachable from this sandbox, so live-endpoint numbers below come from the July 26 run's own recorded data; everything else was reproduced today.

Baseline for comparison: the July 26 run scored **91.2/100, with 81/100 personas passing and 17 failing** (`reports/power-test/NOMVA_100_USER_POWER_TEST_REPORT.md`).

---

## Error 1 — Any empty or malformed AI result becomes a hard 500 (your reported issue) — CRITICAL

**Reproduced today.** When the model returns an empty completion, no choices, null content, or plain text instead of JSON, every LLM-backed endpoint fails the entire request:

```
[empty_content] /v1/classify-intent      → 500 {"error":"classification_failed"}
[no_choices]    /v1/split-foods          → 500 {"error":"split_failed"}
[null_content]  /v1/general-reply        → 500 {"error":"reply_failed"}
[plain_text]    /v1/resolve-food-candidate → 500 {"error":"food_resolution_failed"}
server log: classify-intent error: "undefined" is not valid JSON
```

**Root cause:** `server/index.js` `ask()` (lines 1284–1287) does `JSON.parse(text)` where `text = response.choices[0]?.message?.content?.trim()` can be `undefined`. There is no retry, no guard, and no fallback — the exception propagates and each route maps it to a 500. The same pattern exists in `/v1/analyze-photo` (lines 2374–2377). With reasoning-class models (`gpt-5.*` via `max_completion_tokens`), an empty content field is a routine occurrence, not an edge case — the model can spend its entire token budget on reasoning and return no text.

**Compounding bug:** in `/v1/resolve-food-candidate`, one failed agent turn aborts the whole resolution even though the seeded database search has already found candidates and `foodResolver.js` contains a deterministic fallback (`fallbackResolvedBody`) built for exactly this situation. The fallback only runs on a clean `give_up` — an exception skips it. The guard rail exists; the error path just never reaches it.

**Client impact:** the app doesn't hard-crash here — `handleProviderError` shows "Nomva Cloud didn't finish that request" — but the user's whole message dies and any partially resolved foods are thrown away.

**Proposed solution**
1. In `ask()`: if `text` is empty, retry once immediately (cheap, fixes the majority of transient empties), then throw a typed `EmptyCompletionError`.
2. Wrap each agent turn inside `resolveFoodCandidate` in try/catch; treat a failed turn as `give_up` so the deterministic fallback still returns a real food from the rounds already searched.
3. Map LLM-unavailable errors to 503 with a machine-readable code so the client can distinguish "AI hiccup, auto-retry" from real server faults; keep the existing retry chip as the manual path.
4. Add a regression test that stubs an empty completion and asserts `/v1/resolve-food-candidate` still returns 200 via fallback.

---

## Error 2 — Unvalidated AI numbers can crash the app outright (probable source of your crash reports) — CRITICAL

**Reproduced today (server half), confirmed statically (client half).** The server accepts and forwards absurd numeric output from the model with no upper bound:

```
resolve-food-candidate → {"servings":1e+307, "portionDescription":"a mountain", ...}   (HTTP 200)
resolve-food-candidate → {"servings":25000, ...}                                       (HTTP 200)
extract-servings       → {"servings":9e+99, ...}                                       (HTTP 200)
estimate-grams         → {"grams":1000000000000}                                       (HTTP 200)
```

Validation is lower-bound only: `result.servings > 0` (`index.js:1380`, `2230`, foodResolver.js:265), `grams <= 0` rejected but no ceiling (`index.js:2156`). The client also clamps only the floor: `max(0.1, servings)` (`RemoteAPIProvider.swift:103`).

The app then computes `calories = caloriesPerServing × servings` and renders it with `Int(...)`:

- `ChatView.swift:742, 766, 790, 889, 1400, 1510–1511`
- `FoodLoggingService.swift:825, 2342, 2493–2504`

In Swift, `Int(Double)` **traps fatally** when the value is NaN, infinite, or beyond Int64 range. `147 cal × 1e307 servings` overflows Double to infinity → immediate crash. Even a finite `9e99` exceeds Int64 → same crash. The photo flow is fully exposed too: `/v1/analyze-photo` returns the raw model JSON with `res.json(result)` — zero validation — and `PhotoFoodItem.calories` is decoded straight into `Int($1.calories)` at `ChatView.swift:1511`. Moderate garbage (25,000 servings ≈ 3.7 M calories) doesn't crash but silently corrupts the day's log and every downstream total. Goal values have the same hole (`extract-goal` has no ceiling; goals feed `Int(goals.calories)` in query context).

**Proposed solution**
1. Server: clamp to sane ranges at every numeric extraction point — servings 0.1–100, grams 1–5,000, goal calories 500–20,000, macros 0–2,000 g, photo item calories 0–5,000. Out-of-range → treat as unparseable (422) rather than pass through.
2. Client: add one `safeInt(_ value: Double) -> Int` helper (`value.isFinite ? Int(min(max(value, 0), 9_999_999).rounded()) : 0`) and use it at all listed call sites. This single helper eliminates the entire crash class regardless of what the server sends.
3. Validate `/v1/analyze-photo` output against a schema before `res.json`, same clamps.
4. Add unit tests feeding NaN/1e308/negative values through entry construction.

---

## Error 3 — Client gives up at 15 s while the server routinely needs 18–25 s — HIGH

The app's request timeout is 15 s (`RemoteAPIProvider.swift:621`, default used by `resolveFoodCandidate` at line 89), but the July run's own telemetry shows single `/v1/resolve-food-candidate` requests at p95 9.0 s with worst cases of 21–25 s, food journeys at p50 11.6 s / p95 24.2 s, and all 50 food journeys over the 5 s target. The July 28 single-persona re-run: 18.9 s for one breakfast. So for a large share of real messages the app aborts mid-request, reports "AI didn't return a result," and the server keeps working and burning tokens on an answer nobody will receive — the OpenAI client is constructed with no timeout (`index.js:1254`; SDK default is 600 s) and nothing aborts the LLM call when the phone disconnects. This mismatch *is* the "AI never came back" experience whenever latency spikes, and it stacks with Error 1.

**Proposed solution**
1. Pick one budget and enforce it on both sides: server completes `/v1/resolve-food-candidate` within ~12 s (construct the OpenAI client with `timeout: 10_000, maxRetries: 1`; cap agent turns by wall clock; on deadline, return the deterministic fallback or 422 — never let nginx time out first), and raise the client timeout for the two long routes to 30 s as already done for `analyzePhoto` (line 590).
2. Abort upstream work when the requester disconnects (`req.on("close")` → `AbortController` passed to the SDK).
3. Parallelize per-food resolution server-side and continue streaming stage updates client-side (the cancel/retry UI shipped in `c82fc9f` already supports this).

---

## Error 4 — Four divergent copies of foods.sqlite; the wrong one breaks every food search — HIGH (latent outage)

The repo contains four `foods.sqlite` files with three different schemas: `Nomva/Resources/` (31 columns, 798,763 rows — current), `Resources/` (15 columns, 435,467 rows — stale), `scripts/Resources/` (0 rows), and repo root (0 bytes). Running the unit suite against the stale copy produces `SQLITE_ERROR: no such column: f.saturated_fat_g` in 17 of 38 tests — and this is a runtime error, not a boot error: `createFoodSearchStore` opens the stale file happily and reports available, then **every single food search 500s**. The server's path fallback (`foodSearchStore.js:147–156`) silently prefers whatever file exists, and `deploy.sh` ships only JS files — the production database is unmanaged and unverified. If the Lightsail box ever ends up with the stale file, the entire food pipeline dies with no boot-time signal. All 38 tests pass against the current DB, confirming the code is fine and only the artifact management is broken.

**Proposed solution**
1. Delete `Resources/foods.sqlite`, `scripts/Resources/foods.sqlite`, and the empty root copy; make `Nomva/Resources/foods.sqlite` the single source of truth (or point the others at it via the build script).
2. Add a schema self-check at boot (`SELECT saturated_fat_g FROM foods LIMIT 1`) — fail fast with a clear message and expose DB name/row-count/schema-version in `/health`.
3. Add a checksum-verified DB sync step to `deploy.sh`.

---

## Error 5 — Requests serialize under concurrent load — MEDIUM-HIGH

Six simultaneous food resolutions took 0.51–1.03 s each against a 0.17 s solo baseline (~6× stacking) with the LLM mocked to ~0 ms — the queueing is in the server itself: `better-sqlite3` runs synchronously on the Node event loop, so every FTS query blocks all other requests, and each chat message additionally chains 3–8 sequential LLM round-trips per food. Under real multi-user load this compounds the p95 latencies in Error 3.

**Proposed solution:** move food search onto a worker-thread pool (`better-sqlite3` is worker-safe) or batch the per-message searches; resolve multiple foods from one message in parallel server-side. Re-measure with the same 6-way probe; target <2× stacking.

---

## Error 6 — Coach CSV export still omits hydration — MEDIUM (last open July source-check)

Re-running all July source-check personas against today's code: **19 of 20 now pass** — the team's post-test fixes (`c82fc9f` and neighbors) closed water/target-weight goals via chat, barcode recovery, quick-add favorites, meal templates, VoiceOver row grouping, undo, reduced motion, AI-privacy disclosure, and chat cancel/retry. The one remaining failure is U087: hydration data is included in the full JSON backup but missing from the coach CSV (`Nomva/Services/ExportService.swift`).

**Proposed solution:** add a hydration section (date, total oz, goal oz) to the coach CSV, plus meal names and units per the July feedback; extend the U087 check to assert on real export output rather than source patterns.

---

## Error 7 — analyze-photo leaks internal error detail — LOW

`index.js:2421` returns `detail: err.message` to the client on failure, exposing internals (upstream error strings, file paths). Return the error code only; log the detail server-side.

---

## July failures that needed real-AI behavior (retest after fixes ship)

These can't be verified with a mocked model, but the machinery for each now exists in the code, so they need one live re-run to confirm: relative goal changes ("lower my calorie goal by 200" — U064; `extract-goal` now supports increase/decrease and the client applies deltas), weekly aggregates ("average protein last 7 days" — U070; `deterministicQueryAnswer` now computes these from structured data instead of asking the model), brand/variant preservation (Starbucks grande mocha — U014), composite-dish splitting (tofu bibimbap — U028; the "do not split dish-defining ingredients" rule is now in `prompts.js:88`), grouped "delete that" (U041), and false-success mutations ("Updated Rice" while nothing moved — the typed move-food action now exists but needs end-to-end verification). Raw markdown `**` in chat bubbles is fixed (`ChatView.swift:1653` renders Markdown via `AttributedString`).

## Recommended release gate

Ship only when, in order: (1) Errors 1–2 fixed with their regression tests — these are the crash/reliability core; (2) Error 4's boot-time schema check deployed — it's a silent full-outage risk; (3) Error 3's aligned deadlines in place; then (4) a fresh 100-persona run against the live server clears the July gate: average ≥95, ≥95 passing personas, zero false-success mutations, zero unvalidated-numeric entries, food p50 <5 s / p95 <10 s.

## Evidence

- Fault-injection probes and mock AI: `reports/retest-2026-08-01/` (probe scripts, mock server, raw outputs)
- Source-check re-run (50 personas, U051–U100): `reports/retest-2026-08-01/source-recheck.json`
- Unit tests: 38/38 pass against `Nomva/Resources/foods.sqlite`; 21/38 against the stale `Resources/` copy
- July baseline: `reports/power-test/NOMVA_100_USER_POWER_TEST_REPORT.md`
