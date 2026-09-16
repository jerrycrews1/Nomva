# Nomva 1.5 (45): real meal logging and release checks

## Delivery

The three backend changes are deployed at https://nomva.nerdquad.com. Production health confirms all 804,289 catalog rows are available, and the deployed file hashes match the tested source. The rollback copies are in `/home/ubuntu/nomva-api/deploy-backups/20260915-meal-45/`.

The signed archive is `/Users/jerrycrews/Library/Developer/Xcode/Archives/2026-09-15/Nomva 1.5-45.xcarchive`. Both `com.nomva.app` and its widget are version 1.5, build 45. Production App Attest and HealthKit entitlements are present. The executable SHA256 is `3e042d313f10bc51957622b64e7629e03e23095367f8d50cf4aac4d90296a65b`; all eight changed iOS source, project, and test inputs match the validation checkout.

**Upload is pending.** The first attempt returned `Failed to Use Accounts` while computer control reported a locked Mac. This is a signed archive, not evidence of TestFlight availability. Physical installation and acceptance of build 45 remain unverified.

## What failed and what changed

The reported message was “One chicken breast skinless boneless, half cup broccoli, and one piece of cornbread for dinner.” Production logs at the screenshot time show that classification and planning succeeded, but the client connection closed before the batch resolver returned (HTTP 499). They do not establish why the client closed the connection. The app converted a failed request into three missing-food results, so the reply incorrectly blamed ordinary foods.

- Food resolution now distinguishes an actual missing match from unavailable or malformed responses. A completely unavailable lookup gives a retry message and saves no entries. Successful neighboring slots remain usable.
- Catalog search avoids repeated scans of 800,000 rows and reuses the first candidate search. A small, public reference-food subset lives in process memory; the food database remains read-only. Local search for the three reported foods fell from roughly 2.2 seconds to 0.1 seconds.
- The planner's quantity and the selected catalog row's nutrition multiplier are no longer interchangeable. “Half a cup” keeps the selected row's half-cup weight and nutrition. A piece of cornbread remains one piece in the editor even if its nutrition is a fraction of a catalog serving.
- Portion words no longer distort food identity searches. A generic piece of cornbread must not silently become a branded convenience-store item, stuffing, or chicken dish.
- The bundled catalog path is canonicalized before SQLite's no-symlink check. A new regression reproduced the previous failure through a parent-directory alias. This is an additional verified defect; the logs do not prove it caused this particular screenshot.

The archive and production catalog hashes match: `9debd65ed41eadf15f9d1d01346e5b5115d3d8525f5d08cbdf6a6f38696be9df`. No new storage of personal food histories, weights, or health records is introduced. The temporary search table contains public catalog data.

## Verification and stronger release requirements

The previous tests covered model responses and fixtures without requiring this ordinary meal to pass through the real model, catalog, app persistence, and editor. That left a release gap. Passing an aggregate language score is now insufficient.

| Check | Result |
| --- | --- |
| Regressions before fixes | Catalog alias and real-response portion persistence both failed |
| Full iOS suite | 59/59 passed: 50 core tests and nine UI tests |
| Final portion-display change | All 50 core tests plus both critical food UI journeys passed again: 52/52 |
| Server tests with actual catalog | 182/182 passed, zero skipped |
| Five live authenticated model/catalog journeys on isolated staging | All passed in 4.1–5.9 seconds each |
| Same five journeys against the deployed public API | All passed in 4.0–10.2 seconds; the screenshot dinner took 8.6 seconds |
| Required release verifier | Passed against the final 52-test bundle and all five live journeys |
| Negative gate checks | Rejected a failed test bundle and a core-only bundle missing the live UI regressions |
| Signed archive | App/widget identity, entitlements, catalog hash, and changed iOS inputs verified |

The new UI test submits the exact dinner through the real staging API, requires the meal response within 20 seconds, opens all three saved entries, and checks amounts, weights, calories, and dinner placement. It does not substitute canned food candidates. The final screenshots were also reviewed: chicken was one piece/174 g/288.8 calories, broccoli half a cup/77.5 g/31.8 calories, and cornbread one piece/65 g/186.6 calories. Catalog choices can vary; the deterministic recorded-response core regression separately verifies exact arithmetic for its selected rows.

The live journey gate also exercises rice with explicit grams, eggs, toast, banana, almonds, Greek yogurt, and a single chicken breast. It rejects missing or duplicated foods, unexpected brands or variants, invalid portions, incorrect meals, and excessive latency. During development it caught a 22-second response and an incorrect branded cornbread match; neither was counted as a pass.

`scripts/verify_release_gate.py` requires the named persistence, catalog, failure-handling, dinner UI, and previous bottle-correction regressions plus all five live journeys. `TESTING.md` documents the commands. Backend CI now restores and verifies the actual pinned food catalog before running its tests, preventing those checks from silently skipping when the large database is absent.

Evidence is under `reports/reliability-audit-2026-09-15/meal-release-45/`. The final result bundle is `/tmp/nomva-45-final-portions.xcresult`; the full-suite bundle is `/tmp/nomva-45-release.xcresult`. The isolated API uses the production model configuration and catalog, with simulator-only authentication over a loopback SSH tunnel. The release build cannot accept that test URL override.

These checks establish the repaired software paths and observed live responses. They do not establish physical-device behavior, every possible meal, camera reliability, or Apple Health delivery. Those remain separate acceptance checks.
