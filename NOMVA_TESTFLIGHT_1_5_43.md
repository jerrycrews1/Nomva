# Nomva 1.5 (43) release handoff

## Current delivery state

The backend is deployed at https://nomva.nerdquad.com. Its health check reports the food database available with 804,289 rows. All 35 shipped source/configuration files match the checkout. The previous release is retained at `/home/ubuntu/nomva-api/deploy-backups/20260913T035737Z`.

The signed iPhone archive is ready at `/Users/jerrycrews/Library/Developer/Xcode/Archives/2026-09-12/Nomva 1.5-43.xcarchive`. Both the app and widget are build 43. The archive has production App Attest and HealthKit background-delivery entitlements.

**TestFlight upload is pending.** Command-line export returned `Failed to Use Accounts`; the Organizer follow-up reported that the Mac is locked and automatic unlock failed. Unlocking the Mac is required to finish uploading. Upload, Apple processing, tester assignment, installation, and physical HealthKit delivery have not been established for this build.

## Storage and sync scope

- No new Nomva server sync database or vault was deployed. The proposed encrypted history-sync implementation was removed.
- Weight flow is Garmin Connect → Apple Health → Nomva, plus Nomva → Apple Health. Apple Health handles its own synchronization between Apple devices.
- Food logs, water, goals, custom foods, and chat history remain in the existing protected local store. The update keeps the old cloud-named store file in place rather than switching existing installs to an empty file. Whole-store CloudKit mirroring is off.
- The app no longer offers or calls direct Garmin cloud weight import. The backend returns HTTP 410 with Apple Health instructions for that old endpoint and discards legacy body-composition webhooks. Its previous in-memory weight cache ended when the process restarted.
- Weight notes remain local and are not written to Health metadata or sent for AI processing.
- This is not a zero-data server: the existing AI service processes food requests and retains authentication, subscription/security and operational metadata. The separate optional Garmin activity integration retains its connection credentials and daily activity summaries. Neither is needed for the weight-sync path. Historical iCloud copies are not automatically deleted.

## Repairs

Newer Health revisions now update the matching Nomva weigh-in across devices. Unsent local edits remain queued and receive a revision above the incoming version. Revisions are persisted before export and reused after a failed write or restart. Upgraded legacy records accept a newer Health version instead of re-exporting a stale value.

Health deletions remove clean mirrored weights without re-exporting them. Replacement samples can arrive on a later page without being suppressed, and local notes survive that replacement. Stable IDs, sample aliases and local tombstones prevent duplicate imports and accidental resurrection. Immediate undo remains available before a Nomva-originated Health deletion is sent.

Onboarding and Data Storage settings now describe local history and Apple Health weight sync. The unsupported whole-app iCloud toggle and direct Garmin weight-import controls are removed. Existing chat and barcode reliability fixes are included in the candidate.

## Verification

| Check | Result |
|---|---|
| Final iOS core suite | 40/40 passed on iOS 26.5 Simulator. Includes two independent app stores exchanging edits/deletions through a synthetic Health client, persisted retries, page-split replacements, pending edits, and legacy upgrades. |
| UI suite | 7/7 passed. Includes dated chat weight logging, primary navigation, goals controls, and the Health-only weight settings path. This run also passed the then-current 39 core tests; the final legacy-upgrade addition subsequently passed the 40-test core run. |
| Backend deployment gate | 178/178 passed on the final server source, including authenticated retirement of direct weight import and discard of a known user's synthetic weight webhook. |
| Fresh broad AI evaluation | 200/200 cases, 1,052/1,052 checks passed. Includes 24 source-inspection checks and HTTP retries; this is not 200 physical iPhone flows or a first-attempt reliability measurement. |
| Targeted live chat | 7/7 passed. |
| Live AI latency | Median 843 ms; p95 24,771 ms; maximum 48,001 ms. Cold web-backed food resolution remains a latency limitation. |
| Source and archive | 29 changed app source/configuration files match the validation build. All 35 deployed server files match the checkout. App and widget version/build are verified from the archive. |
| Production health | Passed after restart; App Attest development authentication remains disabled. Existing entitlement audit mode is unchanged. |

The broad AI run used the same AI implementation as the deployment. The subsequent server changes retired the unrelated Garmin weight endpoint/cache and updated privacy text; final server unit/integration tests include those changes.

Evidence is in `reports/reliability-audit-2026-09-12/health-release-43/`. Earlier results and the wider issue review remain in `NOMVA_RELIABILITY_IMPLEMENTATION_2026-09-12.md`.

## Physical acceptance after upload

1. In Garmin Connect, enable sharing Weight with Apple Health and open Garmin Connect after a real weigh-in. Confirm the value and timestamp in Apple Health first.
2. Allow Nomva to read Weight and enable Import Weight History. Repeat Sync Now and relaunch; the weigh-in should appear once.
3. Enable Save Nomva Weigh-ins, log a new weight, then edit and delete it. Verify the corresponding changes in Health. Check undo before deletion is sent.
4. On the second Apple device, use the same Apple Account, enable Health in iCloud, grant Nomva Weight access and enable import. Verify a new entry, edit and deletion across devices. Apple determines propagation timing.
5. Confirm existing local history survives upgrading the installed app. Test actual camera barcodes; API and simulator tests cannot prove camera recognition or HealthKit delivery.

[Apple Health sync identifiers](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier) and [Garmin's Apple Health sharing guidance](https://support.garmin.com/en-US/?faq=lK5FPB9iPF5PXFkIpFlFPA) explain the underlying exchange behavior.
