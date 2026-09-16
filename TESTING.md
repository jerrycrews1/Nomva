# Nomva Quality Gates

Nomva uses three different test layers. A green deterministic suite does not, by
itself, prove that the live model behaves correctly.

## Required Gates

1. Every change: run all server tests and the iOS core suite.
2. AI or prompt changes: also run the held-out live chat evaluation.
3. Before TestFlight: run the full iOS core and UI suites, including
   `testReportedDinnerThroughLiveChatAndSavedLog` against an isolated API using
   the candidate server code, deployed model configuration and actual food DB.
   Run `server/scripts/run_food_journey_gate.js` as well. Every journey must
   pass; a missing food, wrong identity/quantity, zero nutrition or response
   over 20 seconds blocks upload. A 95% language score cannot override these failures.
4. Before App Store submission: repeat the held-out evaluation against the exact
   deployed model configuration and complete the device/integration checklist.

Commands:

```sh
(cd server && npm test)
xcodebuild test -project Nomva.xcodeproj -scheme Nomva \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:NomvaTests
(cd server && npm run eval:security-smoke)
```

The live evaluation requires `OPENAI_API_KEY`. It is intentionally not part of a
watch loop. Run it only for an AI release candidate so it does not waste API
tokens. A release passes only at 95/100 or better. Training cases may guide fixes;
validation cases must remain held out.

## Food journey release gate

The former multi-food test supplied already-resolved synthetic apples, while the
live language evaluation graded individual model responses. Neither exercised
the app's HTTP error handling, real catalog lookup, candidate-relative servings,
or final saved dinner. The September 15 screenshot is a permanent regression.

Use a candidate API bound to loopback with a separate temporary data directory,
the production model settings and food database, and simulator authentication.
Forward it with SSH to `127.0.0.1:18445`. Production authentication stays enabled.
The UI suite fails if this API is absent; it must never skip or fake the live test.
`NOMVA_LIVE_API_URL` accepts loopback URLs only in debug simulator builds.

```sh
node server/scripts/run_food_journey_gate.js \
  --base-url=http://127.0.0.1:18445 --report=/tmp/nomva-food-journeys.json
xcodebuild test -project Nomva.xcodeproj -scheme Nomva \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:NomvaTests -only-testing:NomvaUITests \
  -resultBundlePath /tmp/nomva-release.xcresult
python3 scripts/verify_release_gate.py --tests=/tmp/nomva-release.xcresult \
  --journeys=/tmp/nomva-food-journeys.json
```

The executable verifier rejects missing/failed/zero-test results, absent named
production regressions, and any failed required food journey. Keep failed runs
as evidence. Fix the cause and rerun affected checks rather than increasing the
time or nutrition bounds to obtain a pass. Retain the archive version, catalog
hash and deployed source hashes with the passing evidence.

The live UI test starts from an empty log, types the exact dinner, waits for a
complete receipt, then opens each of the three saved rows. The core regression
checks exact grams/calories after fetching from a new SwiftData context, and
opens the shipped catalog through an aliased container path. Network failures
must remain recoverable service failures rather than becoming food mismatches.
These are software gates; TestFlight installation and physical HealthKit/camera
acceptance remain separate checks.

This approach follows [OpenAI's task-specific evaluation guidance](https://developers.openai.com/api/docs/guides/evaluation-best-practices#design-your-eval-process).

## Coverage Matrix

| Area | Required behavior | Automated coverage |
| --- | --- | --- |
| Food create | One food, multiple foods, repeated catalog item, quantities, units, composite dishes, meal/date, partial resolver failure | Server batch properties; iOS plan-to-resolve-to-persist contract |
| Food read | Daily totals, meal totals, calories remaining, history/context, empty day | Server CRUD eval; iOS nutrition invariants |
| Food update | Portion, identity, meal move, correction referring to earlier turns | Conversation eval; client service tests; UI smoke for long-press move |
| Food delete | One, pronouns, grouped items, all/day/meal, already deleted, ambiguous target | Server target guards; client exact-entry allowlist; conversation eval |
| Food discovery | Local search, branded foods, recent/favorite foods, barcode, nutrition-label photo, world-food fallback | Resolver tests plus device checklist |
| Water | Add/set/delete/clear, oz/cups/ml, today/yesterday, ambiguous quantity | Server CRUD and adversarial eval |
| Weight | Add/update/delete, lb/kg, date, import/dedup/export, Apple Health and Garmin | iOS sync and archive tests plus device checklist |
| Goals | Calories/macros, partial update, activity adjustment, macro reconciliation | Server exact-metric eval; iOS goal math tests |
| Persistence | Every planned food saved exactly once; archive round trip; concurrent request serialization | iOS SwiftData and concurrency tests |
| API contract | Auth required, malformed/empty/duplicate/out-of-range batch slots rejected, bounded payloads | Server integration tests; iOS decoder tests |
| Subscriptions | Purchase, restore, cancellation, TestFlight access, readable errors | Copy unit tests plus StoreKit/TestFlight checklist |
| UI/accessibility | Navigation, hit targets, light/dark mode, largest text, swipe delete, scanner errors | UI smoke tests plus screenshot/device checklist |
| Misuse/security | Prompt injection, prompt extraction, fake system text in food/log data, destructive target hallucination, script/SQL/control text, oversized input | Security prompts, server guards, generated adversarial properties, held-out live eval |

## Security Invariants

- User messages, food names, brands, labels, search results, logs, and conversation
  history are untrusted data, never instructions.
- Model output is a proposal. The server validates its schema and the client or
  server validates destructive targets against current persisted state.
- A model cannot delete or edit a food name that is not an exact current-log item.
- Indexed batch responses must contain every requested slot exactly once. A failed
  slot must explicitly contain an error; one failure cannot erase its neighbors.
- The app never displays provider internals, hidden prompts, credentials, or raw
  StoreKit errors.

## Device And External-Service Checklist

Automation cannot fully simulate Apple accounts, StoreKit production behavior,
camera focus, HealthKit permissions, the Garmin-to-Apple-Health bridge, or TestFlight receipt
state. Before release, verify on a physical device:

- Add, edit, move, favorite, copy, and swipe-delete foods in every meal.
- Log 1, 2, 5, and 12 foods in one message and verify item count and totals.
- Correct and delete items using references from one to three messages earlier.
- Scan a known and unknown barcode in light and dark mode.
- Photograph a readable and unreadable nutrition label; cancel midway.
- Deny, partially allow, then allow HealthKit; import history twice without duplicates.
- Verify Garmin → Apple Health → Nomva and Nomva → Apple Health with real weights;
  repeat import/export without duplicates. Do not treat direct Garmin weight sync
  as the supported path.
- Purchase and restore with StoreKit sandbox and verify TestFlight tester access.
- Interrupt requests with airplane mode, backgrounding, timeout, and app relaunch.

## What A Passing Score Means

The deterministic tests check known contracts and generated
invariants. The live score samples natural-language behavior; it cannot prove every
sentence a person may type. New production failures become permanent regression
cases in both the smallest deterministic layer and, when language-dependent, the
held-out evaluation.
