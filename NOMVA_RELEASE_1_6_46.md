# Nomva 1.6 (46) release evidence

Status: source, regression checks, production deployment, public documentation, and signed archive complete. Apple processing is complete and the internal Testers group has build access. Public version 1.6 (46) was submitted and is Waiting for Review, with automatic release to all users after approval. Physical-device acceptance remains unverified.

## What changed

- Activity calories now flow from the selected source into the same target in Chat, Log, and widgets. Apple Health uses daily active-energy samples and a completed-day baseline; missing days and real zero-activity days remain distinct. Observer, launch, foreground, and permission/source changes refresh the data. Status shows the source, baseline, check time, and recoverable errors.
- Garmin summaries use coverage and summary identity so delayed partial data cannot overwrite a fuller day while legitimate corrections can reduce an earlier total. Failed syncs preserve cached values, show an error, and remain retryable.
- Weight synchronization keeps Apple Health as the Garmin bridge. Import, deletion, and export failures are handled independently; full-history rechecks preserve deletion suppression and only advance successful cursors. Cancellation, changes during an export, and stalled pagination have regression coverage.
- Chat requests have a total deadline, cancellable work, persisted delivery state, and explicit retry recovery. Only replayable requests retry transient transport errors; server inference retries share the original deadline. Authentication, billing, cancellation, and malformed responses do not silently retry. A planner outage no longer falls through into an unrelated interpretation pipeline.
- Save failures are visible. Widget actions remain queued until persistence succeeds. Backups restore atomically, preserve weight-deletion history, and retain a protected pre-restore recovery copy. Subscription verification recovers on foreground and excludes revoked, upgraded, or expired transactions.
- Privacy manifests, policy, support, marketing, storage copy, release notes, and version/build display match the implementation. Empty chat content stays at the top; activity detail wraps at accessibility sizes.

The fixes use shared state, request policies, source metadata, and persistence contracts. Simulated activity exists only behind a DEBUG UI-test fixture; production behavior has no test-food or user-specific bypass.

## Validation

| Check | Result | Evidence |
| --- | --- | --- |
| Server regression suite, production Node 24/catalog | 190/190 passed; no skips | `reports/release-46/server-tests-final-2.log` |
| Full iOS suite | 73/73 passed: 62 core, 11 UI; no skips | `/Users/jerrycrews/Developer/NomvaRelease46Evidence/nomva-46-full-3.xcresult`, `reports/release-46/full-3-summary.json` |
| Final privacy packaging/settings checks | 63/63 passed: 62 core, accessibility Settings UI | `/Users/jerrycrews/Developer/NomvaRelease46Evidence/nomva-46-final-packaging.xcresult` |
| Final chat layout and live Stop/Retry/background regression | 2/2 passed | `/Users/jerrycrews/Developer/NomvaRelease46Evidence/nomva-46-final-chat.xcresult`, `reports/release-46/activity-chat-final.png` |
| Real authenticated food journeys | 5/5 passed, 4.5–8.8 seconds | `reports/release-46/live-food-journeys-2.json` |
| Held-out AI evaluation | 98.2/100, 168/171 checks; 97/100 fully passing cases | `reports/release-46/heldout-eval.json` |
| Required release gate | Passed all required tests and food journeys | `scripts/verify_release_gate.py` |
| Release archive | Succeeded; app/widget identity and manifests verified | `reports/release-46/archive-identity-final.json` |
| Whitespace/diff validation | Passed | `git diff --check` |

The full suite ran before the final privacy resources, support/version link, and activity-layout changes. Core tests plus affected Settings and activity/chat UI tests were rerun after those changes; the final empty-chat scroll guard was covered by the two final UI tests. The archive contains those final bytes. `build-inputs-full-3.json` and `build-inputs-final.json` identify each tested source set (82 final build inputs).

The three held-out misses were exact search-query expectations: two expected “fresh spinach” but received “spinach”; one expected “waffle fries” but received “Chick-fil-A fries.” Follow-up real resolution returned raw spinach and the correct branded waffle fries, with uncertain portions explicitly estimated. The original failures remain recorded; no prompt or evaluation expectations were changed to hide them. See `search-query-followup.json`.

A first live dinner run exposed an upstream planner timeout; that failure drove the bounded recovery change. Both the original failure report and successful rerun are retained. Automated outcomes do not establish physical HealthKit permission/background delivery, Garmin sharing, or App Store purchase acceptance.

## Production and store metadata

- Backend changes and `index.html`, `privacy.html`, `support.html` deployed to `https://nomva.nerdquad.com`; health check passed with 804,289 catalog rows. Public pages were fetched and matched the committed source hashes exactly.
- Previous live source and a consistent SQLite snapshot are retained at `/home/ubuntu/nomva-api/deploy-backups/release-46-20260922/`. Existing production data was preserved; the Garmin coverage column is additive.
- Deployment receipts: `reports/release-46/deploy.log`, `production-health.json`, `production-source.sha256`, `server-promote-hashes.json`, `public-page-verification.json`.
- App Store Connect app **6762495287**, Nomva, bundle **com.nomva.app**, team **9UXM4W53T6**. Version **1.6 (46)**, widget **com.nomva.app.widgets**.
- Version 1.6 draft created with build 46 selected; revised description and What’s New saved. Existing support/privacy URLs point to the updated pages. Public review submission accepted on September 21, 2026; version status is Waiting for Review.
- Replaced obsolete “Data Not Collected” declarations. Nine data categories are published: Health, Fitness, Photos or Videos, Other User Content, User ID, Device ID, Purchase History, Performance Data, Other Diagnostic Data. Each is for app functionality, linked to identity, and not used for tracking. No incomplete category setup remains.
- The terms document remains an unpublished draft; Apple’s Standard EULA is still operative.

## Delivery and remaining acceptance

Final signed archive: `/Users/jerrycrews/Library/Developer/Xcode/Archives/2026-09-21/Nomva 1.6-46-final.xcarchive`.

The earlier `Nomva 1.6-46.xcarchive` predates the empty-chat scroll correction and must not be used for release. The final archive is development-signed before automatic App Store distribution export; archive signing alone is not distribution or tester availability evidence.

- [x] Canonical identity, final source manifest, signed archive, app/widget privacy resources checked.
- [x] Automated core/server/UI tests and real food journeys passed.
- [x] Production backend and public documentation deployed and verified.
- [x] App Store description/release notes and published privacy declarations updated.
- [x] Upload accepted by Apple at 21:02 PDT on September 21, 2026: `Uploaded package is processing.`, `Upload succeeded.`, and `EXPORT SUCCEEDED`. Initial account-access failure was resolved by restoring the Xcode account session. Evidence: `reports/release-46/upload-final.log`.
- [x] Apple processing complete. App Store Connect shows version 1.6 build 46 upload Complete, with the internal Testers group (one tester) assigned. Build status is Ready to Submit for external review. Focused What to Test instructions are saved.
- [x] Final archive installed in place and launched on the physical iPhone 17 Pro. The first attempt using a cached CoreDevice identifier timed out; the current device UDID succeeded. Evidence: `reports/release-46/device-install-2.log`, `device-launch.log`. Existing record contents have not yet been visually compared.
- [ ] Physical acceptance: compare Garmin/Health activity with Nomva’s selected-source total; foreground refresh, background delivery, permission changes, and day rollover; import/export/deletion of an intentionally entered weight; interrupted chat recovery; StoreKit restore/subscriber/expired access.
- [x] Public App Store review submission accepted following the user’s request to push the next public release. Submission ID: `06334d7a-8601-47f3-ba2e-d0e4ab885ee0`. Status: Waiting for Review. Automatic release after approval is enabled, with immediate availability to all users. The physical acceptance items above remain unverified.
- [ ] Apple review approved and public App Store availability verified.

The build mirror `/Users/jerrycrews/Developer/NomvaRelease46` avoids macOS FileProvider metadata stalls in Documents. Final source bytes were copied from the canonical repository and verified by SHA-256; the mirror is not a separate source of truth.
