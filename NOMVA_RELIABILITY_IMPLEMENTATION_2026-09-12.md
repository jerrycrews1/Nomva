# Nomva reliability implementation — September 12, 2026

**Latest delivery update:** [Nomva 1.5 (43)](NOMVA_TESTFLIGHT_1_5_43.md) supersedes the deployment and weight-sync status below. This earlier report is retained as the broader audit record.

The chat, barcode, and Apple Health fixes are implemented in this checkout. This is a candidate for device testing, not a production release. The final live evaluation after the restaurant identity repair is recorded below.

The intended weight route is **Garmin Connect → Apple Health → Nomva**, with **Nomva → Apple Health** for Nomva-authored weigh-ins. Direct Garmin import remains a legacy option with limited history coverage.

## What changed

| Area | Previous failure | Implemented behavior |
|---|---|---|
| Chat saves | Success text could conceal unresolved foods or disagree with saved rows. | Confirmations are generated from persisted entries. Successful foods remain saved; unresolved foods are named and retained for clarification. |
| Corrections | Ambiguous names and fallback selection could change the wrong entry. | Exact IDs or unique names identify targets. Meal scope narrows selection; missing or ambiguous targets require clarification. |
| Conversation | Follow-ups lost their target, and dated actions could move the conversation offscreen. | Saved receipts retain food IDs. The conversation stays on its selected day; actions and pending clarifications retain their own log date. |
| Multiple actions | A food request combined with a weigh-in could lose one action. | Supported food/weight clauses execute separately with individual dates and save receipts. Compound corrections/deletions request clearer scope. |
| Weight chat | Weight queries depended on cloud context and could enter an edit path. | Weight logging, corrections, deletion, and supported history calculations run locally. Queries do not become edits; missing edit targets do not create new weigh-ins. |
| Dates and units | Relative dates, kilograms, and midnight batches could produce wrong records. | Calendar-based relative dates, ISO/named dates, explicitly cued US dates, exact kg/lb conversion, invalid-date rejection, and same-day batch timestamps. |
| AI answers | Generic fallback text and weak context made failures look like answers. | Contextual replies use the configured context model, retain relevant conversation, disclose missing data, and distinguish provider failures. |
| Request latency | A failed batch could trigger many sequential fallback calls. | Single-item fallback is limited to unsupported batch endpoints. Canceled queued requests are removed; interactive requests take precedence over background work. App Attest request ordering is retained. |
| Restaurant search | Model misses were cached as absence, and valid bowls with white rice could fail an overly broad identity guard. | Model misses no longer become cached absence. Identity matching distinguishes white rice from an egg-white substitution and preserves explicitly requested variants. Planner-identified, inferred, and recognized named-chain orders select the configured menu model. Packaged products and homemade copycats retain their appropriate lookup path. Positive results retain their nutrition provenance. |
| Barcode identity | UPC/EAN padding differences and UPC-E representation caused misses. | GTIN validation and canonical identity support EAN-8, UPC-A, EAN-13, GTIN-14, and scanner-aware UPC-E expansion. Database lookup uses indexed aliases. |
| Barcode coverage | A bundled-database miss often ended the search. | Exact Open Food Facts lookup, a persistent positive cache, short-lived true misses, request coalescing, provider throttling, and offline cache recovery. |
| Barcode nutrition | Units and absent values could be treated incorrectly. | Normalize provider units, require calories/protein/carbs/fat, preserve genuine zeros, identify missing secondary nutrients, and avoid gram scaling when the mass/volume basis is unknown. |
| Scanner recovery | Delayed results, outages, and missing products were hard to distinguish. | Permission handling, scan lifecycle improvements, lookup progress, stale-response cancellation, and separate invalid/missing/incomplete/unavailable messages. Custom-food creation retains the scanned code. |
| Health import | Broad rescans and approximate deduplication lost source identity and deletions. | Paged anchored reads, durable cursors, source IDs/aliases, exact updates/deletions, and narrowly scoped Garmin-to-Health reconciliation. Distinct nearby weigh-ins remain distinct. |
| Health export | Repeated exports, failed writes, and deletion could lose synchronization state. | Durable pending fingerprints and sync versions are saved before Health writes. Retries reuse the version; unchanged values are skipped. Deletion records support delayed deletion and undo. |
| Health lifecycle | Sync depended too heavily on manual actions. | Foreground refresh and HealthKit observation process imports and retry pending exports. Settings show last checks, source information, pending work, and errors. |
| Local storage | Store-open failure could silently create a writable temporary replacement. | Existing stores are preserved. Startup failure blocks logging and offers retry instead of accepting data into a temporary store. |

### Material change: iCloud mirroring is paused

The legacy SwiftData store combines health measurements, goals, notes, and nutrition records. Its CloudKit mirroring is disabled in this candidate. Existing installations continue using the same on-device store file, including the legacy cloud-named file; the code does not switch them to an empty store or delete prior iCloud copies.

The local store directory is protected and excluded from backup. Automatic weight history and health-derived goal context are excluded from cloud AI conversation context. Weight questions use local records. The shared iCloud settings control explains the pause.

This affects cross-device syncing of the legacy shared store, including food records. Restoring eligible cross-device features requires a separate storage design and migration review. Apple Health is the weight exchange route in this implementation. Apple's guidance prohibits storing personal health information in iCloud. [App Review health guidelines](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research)

## Validation and its limits

All live model checks used the existing Lightsail configuration, located without copying its OpenAI secret to the local checkout. A temporary candidate server listened on loopback, used synthetic accounts and isolated writable data, and read the existing food database. The production process and production user records were not changed.

| Check | Evidence and outcome |
|---|---|
| Server suite | 178/178 tests passed on Node 24.18.1 with the food fixture configured, including restaurant identity, named-chain routing, and packaged-food/copycat regressions. Earlier Node 22 runs passed the preceding 172-test suite. |
| iOS core | 36/36 core tests passed on the current source, including the conversation-date changes. Test stores now explicitly disable CloudKit and retain their containers to prevent fixture connection failures. Tests cover saved food receipts, partial failures, duplicate identities, dates, units, barcode normalization/cache recovery, canceled requests, anchored imports, deletion suppression, and Health export retry. |
| Durable Health state | A real temporary SQLite store was reopened after a simulated failed export. The pending version and deletion suppression survived, and retry reused the original version. This validates persistence behavior, not HealthKit delivery. |
| iPhone UI | The final full run passed 5/6 scenarios; the Goals test process terminated before its tap with “Test crashed with signal term.” That unchanged scenario passed its focused rerun. The dated-weight conversation scenario passed on current source: its reply remained visible and its record appeared in Weight history. All six scenarios have passed, but the final full run itself was not green. |
| Live chat scenarios | Seven targeted checks passed: separate foods, independent repeated servings, pending-food-only clarification, missing delete target, grounded coaching, missing weight data, and no invented save confirmation. Coaching text was manually reviewed. |
| Broad live evaluation | Broad candidates: 195/200, 197/200, then 199/200 after the rice-identity repair. The last broad miss was a large Wendy’s chili order; named-restaurant routing was then repaired. The evaluation includes 24 source-inspection checks; it is not 200 full iPhone user flows. HTTP retries are included, so these scores do not measure first-attempt success. |
| Focused live regressions | Language/date-query/meal-label failures were repaired. Both chicken-bowl cases passed the latest broad run after the identity repair. The final six restaurant checks passed 6/6 after the named-chain routing repair, covering Wendy’s chili and the chicken bowl both alone and in mixed-food requests. Do not combine focused reruns into a claimed 200/200 result. |
| Live barcode API | Three known GTINs returned matching products with required nutrition fields: Nutella, Coca-Cola, and a Thai peanut noodle kit. These were direct lookup checks, not camera scans. |
| Source comparison | Source changes were compared with GitHub commit `a6e5846105637241e7c137f2638331c7264e8a19`. A patch and hash manifest are retained with the evidence. All 26 changed iOS source/configuration files match the validation build, and all 11 server files included in the live probe match the checkout. The Node-version hint and static privacy page were not included in the live probe. |

The latest broad live run reached 199/200 with a median case duration of 875 ms, a p95 of 17,112 ms, and a maximum of 25,291 ms. An earlier diagnostic probe showed that two valid, source-backed chicken-bowl responses were rejected because “white rice” triggered the egg-white variant guard. That defect is repaired, with regressions for valid rice components, wrong meat, egg substitutions, and explicitly requested rice variants. Cold web lookups still take substantially longer than ordinary requests; final evaluation results are recorded below.

Local macOS file offloading interrupted repository reads and some tooling. Validation used an existing local copy of the project with current changed source synchronized into it. Original Git metadata was left intact; the source review used the verified GitHub baseline. These host issues are separate from physical iPhone acceptance.

Evidence is in `reports/reliability-audit-2026-09-12/`, including source manifests, the broad live result, barcode payloads, and Xcode logs. Final remote validation reports are retained in its `verified-server-evidence/` subdirectory; earlier snapshots remain in `final-server-evidence/`. The most recent broad result is `verified-server-evidence/reports/release-gate-pass5/latest-holdout2-200.json`; the final focused result is `verified-server-evidence/reports/release-gate/latest-holdout2-6.json`.

## Phone acceptance checklist

Use the intended device and the new candidate build. Simulator or server results cannot establish this chain.

1. **Garmin into Apple Health:** make a real weigh-in, finish Garmin Connect synchronization, and verify the original value and timestamp in Apple Health. If it is absent there, investigate the Garmin/Health connection before testing Nomva import.
2. **Apple Health into Nomva:** enable Weight read access and import. Verify value, unit conversion, timestamp, and source. Repeat sync and reopen Nomva; the record must still appear once.
3. **Nomva into Apple Health:** enter a real Nomva weigh-in, verify the matching Health record, then reopen and sync repeatedly. Edit it and confirm the update without a second independent sample. Imported Garmin/Health records must not be exported as new Nomva records.
4. **Failure recovery:** revoke write access or interrupt synchronization after the local save. The local weigh-in must remain, the pending state must survive restart, and retry after restoring access must not duplicate it.
5. **Deletion and undo:** delete a Nomva-authored weigh-in and test immediate undo. Test deletion after the delay. Delete an imported record in Nomva and confirm it stays hidden across imports without deleting another app's Health data.
6. **Apple-side changes:** change/delete an imported sample at its source and verify the anchored import updates Nomva. Test two genuine weigh-ins close together so deduplication cannot hide one.
7. **History and permissions:** test more than 500 samples, a clean install, upgrade of an existing store, denied read access, and relaunch. Empty Health results must not be presented as proof that permission was granted or that no history exists.
8. **Chat:** log a mixed food/weight request, correct a food by reference, clarify only a failed food, and log a past-date weigh-in. Confirm the reply remains in the visible conversation and the data lands on its requested date.
9. **Camera:** try a representative grocery set in normal and poor light, including UPC-E/EAN variants, a missing product, an incomplete label, airplane mode, denied camera access, and rapid repeated scans. Confirm no late result replaces a newer scan.

Anchored queries are the HealthKit mechanism used to process both additions and deletions. [Apple HealthKit documentation](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery)

## Remaining work, in priority order

| Priority | Issue | Next concrete step and acceptance |
|---|---|---|
| P0 before release | Physical weight exchange and existing-store upgrade are unverified. | Complete the phone checklist with the intended Garmin/Apple/Nomva chain and preserve before/after counts and sample IDs. |
| P0 before release | The latest full AI evaluation remains 199/200; its last failure was repaired afterward. | Complete a fresh broad evaluation on the final release candidate, with cold restaurant requests included. Preserve failure reasons and stage timing, review exact serving/source correspondence, and measure first-attempt success separately from HTTP retries. |
| P1 | Legacy iCloud behavior changed materially. | Review upgrade behavior and recovery with a populated existing cloud store. Design any eligible replacement synchronization separately from protected health storage. Before supporting concurrent weight edits from multiple Nomva devices, define and test how higher Health sync versions resolve against local edits. |
| P1 | Direct Garmin history is incomplete and process-cached. | Keep the Apple Health route primary. If direct import remains supported, expose actual upload windows and per-window diagnostics, preserve successful partial windows, and define a durable cache/retention contract. Do not advertise a complete year of history. |
| P1 | Production entitlement enforcement remains in audit mode. | Verify real signed-device subscription and App Attest flows before enabling enforcement. Keep debug/test access separate from production authorization. |
| P1 | Some broader conversation operations still use separate legacy endpoints. | Introduce a typed turn plan with explicit targets, dates, required clarification, and execution receipts; evaluate compound edits and multi-date comparisons before expanding automatic execution. |
| P1 | Unknown secondary nutrition is not yet represented consistently throughout every stored total and report. | Carry nutrient-availability metadata through entries, aggregates, exports, and goals instead of implying complete measurements. |
| P2 | Activity-based calorie calculations and direct Garmin activity corrections need a separate pass. | Verify corrections that reduce previously reported totals and ensure incomplete activity history does not inflate targets. |
| P2 | Some saves, conversation clearing, archival restore, and undo paths still merit broader transaction coverage. | Add focused failure/restore cases around actual user operations; do not treat source-string checks as functional coverage. |
| P2 | Camera focus, scan region, accessibility, and real-world recognition remain unproven. | Complete a physical barcode corpus and VoiceOver/Dynamic Type review; measure camera detection separately from product lookup. |
| P2 | End-to-end observability needs expansion. | Record privacy-preserving stage durations, lookup outcomes, retries, saved/unresolved item counts, and sync cursor/outbox status. Keep raw health values and messages out of routine telemetry. |

## Release handoff

No production deployment, database replacement, TestFlight upload, or physical-phone installation was performed. Keep the candidate backend isolated until its release checks are accepted. Use the existing deployment workflow only after validating the candidate build against that backend, with source hashes and a rollback build retained.

The initial detailed plan remains in `NOMVA_RELIABILITY_FIX_PLAN_2026-09-12.md`. This document records what was implemented and what still needs evidence; it does not mark the entire roadmap complete.

### Final verification update

Current app source matches all 26 changed iOS source/configuration files in the validation build. All 36 core tests pass. The six UI scenarios have passed across the full run and focused rerun, with the terminated test-process limitation retained above. The 40-file source comparison has no whitespace findings. The final backend passed 178/178 unit tests, 7/7 targeted live chat checks, and 6/6 focused restaurant regressions. The latest full live evaluation remains 199/200 because it preceded the last routing repair; no combined 200/200 result is claimed. The validation helper’s console label was subsequently corrected to distinguish focused runs; that label-only change passed a syntax check.
