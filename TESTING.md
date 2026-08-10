# Nomva Quality Gates

Nomva uses three different test layers. A green deterministic suite does not, by
itself, prove that the live model behaves correctly.

## Required Gates

1. Every change: run all server tests and the iOS core suite.
2. AI or prompt changes: also run the held-out live chat evaluation.
3. Before TestFlight: build the simulator target and run UI smoke tests.
4. Before App Store submission: repeat the held-out evaluation against the exact
   deployed model configuration and complete the device/integration checklist.

Commands:

```sh
cd server && npm test
xcodebuild test -project Nomva.xcodeproj -scheme Nomva \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:NomvaTests
cd server && npm run eval:security-smoke
```

The live evaluation requires `OPENAI_API_KEY`. It is intentionally not part of a
watch loop. Run it only for an AI release candidate so it does not waste API
tokens. A release passes only at 95/100 or better. Training cases may guide fixes;
validation cases must remain held out.

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
camera focus, HealthKit permissions, Garmin OAuth/webhooks, or TestFlight receipt
state. Before release, verify on a physical device:

- Add, edit, move, favorite, copy, and swipe-delete foods in every meal.
- Log 1, 2, 5, and 12 foods in one message and verify item count and totals.
- Correct and delete items using references from one to three messages earlier.
- Scan a known and unknown barcode in light and dark mode.
- Photograph a readable and unreadable nutrition label; cancel midway.
- Deny, partially allow, then allow HealthKit; import history twice without duplicates.
- Connect, disconnect, reconnect, and expire Garmin authorization.
- Purchase and restore with StoreKit sandbox and verify TestFlight tester access.
- Interrupt requests with airplane mode, backgrounding, timeout, and app relaunch.

## What A Passing Score Means

The deterministic tests exhaustively protect known contracts and generated
invariants. The live score samples natural-language behavior; it cannot prove every
sentence a person may type. New production failures become permanent regression
cases in both the smallest deterministic layer and, when language-dependent, the
held-out evaluation.
