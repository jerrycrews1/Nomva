# Nomva 1.7 (49) App Store submission

Submitted September 23, 2026 at 21:10 PDT. App Store Connect reports **Waiting for Review** for version 1.7 and review submission `e14b34dd-0a1d-40f6-94bc-fe6d6ed9dc6a`. Release type is **After Approval**; Apple approval and public availability are not yet established.

## Build and validation

- Source commit: `ce1cac8` on `codex/nomva-health-sync-testflight`. The version bump from TestFlight build 48 to public build 49 is the only source change in that commit. Weight-write recovery is in `2f325c1`; the navigation performance fix and measurement are recorded in `NOMVA_PERFORMANCE_2026-09-23.md`.
- The signed archive at `/Users/jerrycrews/Library/Developer/Xcode/Archives/2026-09-23/Nomva 1.7-49-public.xcarchive` succeeded. App and widget are both 1.7 (49), team `9UXM4W53T6`, with valid signatures. The packaged food database SHA-256 is `9debd65ed41eadf15f9d1d01346e5b5115d3d8525f5d08cbdf6a6f38696be9df`.
- Xcode upload succeeded using App Store distribution without the internal-only TestFlight setting. Apple build `0628be8e-2bc0-4605-9b13-81bbd04f70ab` is `VALID` and `APP_STORE_ELIGIBLE`; its upload is `COMPLETE` with no errors or warnings.
- The focused permission-denial/retry UI tests and 62 core tests passed for the build 48 source. Build 49 changes the build number only. A separate Debug simulator screenshot test from the build 49 source passed (1 test, 0 failures); it is visual listing evidence, not a physical-device or signed Release runtime test.

## Store listing and review

- The 1.7 `en-US` What's New explains responsiveness, estimate language, Health write permission recovery, local saving after denial, and retry of a saved weigh-in. The build, support URL, marketing URL, review contact, and automatic release setting were checked before submission.
- Five processed 6.9-inch screenshots remain in the 1.7 listing: AI Chat, new Log, new Nutrition Details, new Weight overview, and new Settings. The older weight, insights, and settings screenshots with obsolete or unsupported claims were removed. The older 6.5-inch set was removed; Apple scales the required 6.9-inch set for that size.
- Review submission item `ZTE0YjM0ZGQtMGExZC00MGY2LTk0YmMtZmU2ZDZlZDlkYzZhfDZ8ODkxOTAzMzgy` contains version 1.7. App Store Connect readback reports submission and version `WAITING_FOR_REVIEW`, five screenshots `COMPLETE`, and the correct build relationship. The local machine-readable receipt is `reports/release-49/submission-receipt.json`.

## Remaining acceptance

- Apple has not approved or published 1.7. After approval, confirm the public App Store page and install/update availability.
- Build 49 has not been installed or tested on a physical iPhone. Recheck Apple Health permissions, local weigh-in persistence, sync recovery, navigation feel, and purchase/restore behavior on device.
- Trademark clearance, original icon provenance, and counsel review noted in `LEGAL_REVIEW_RELEASE_HANDOFF_2026-09-23.md` remain open; this submission does not establish legal clearance.

Detailed local logs, upload receipts, and the final simulator captures are preserved under `reports/release-49/` (ignored by Git). The signed archive is preserved separately.
