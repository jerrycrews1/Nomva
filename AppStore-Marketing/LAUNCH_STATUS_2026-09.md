# Nomva promotion execution status

Updated September 22, 2026. This records completed work and the evidence still needed before the broad organic launch. Source plan: `LAUNCH_2026-09.md`.

## Complete

| Item | Evidence |
| --- | --- |
| Public landing page and App Store CTA | `https://nomva.nerdquad.com/` serves the updated `server/public/index.html`. The live file SHA-256 matched local `b24a55a16b161fbb8921be56804b521066ed4d6d196cc6e9992f77210b75c72f` after the 20:50 UTC update. Two App Store links, support, privacy, title, and description were checked live. The page now has an iPhone App Store banner and uses the original launch card for social previews; the public PNG hash matches local `50d7a3dc0b8608c396fffa1c87982f86df5c3e3240e8c6f165e6a7675026d00c`. The prior server file is backed up as `index.html.backup-20260922T205033Z` (earlier backups are retained). |
| Current public listing | The [US App Store listing](https://apps.apple.com/us/app/nomva/id6762495287) and iTunes public lookup show Nomva 1.6, released September 22, 2026, free with Nomva Pro Monthly listed at $4.99 in the US. The App Store Connect API confirms iOS version 1.6 is `READY_FOR_SALE` with build 46. |
| Subscription product state | The App Store Connect API returned `APPROVED` for `com.nerdquad.nomva.pro.monthly` with a one-month period. This establishes product approval, not a successful customer purchase or payout configuration. |
| Analytics collection | Created a one-time historical snapshot request (`7ba80b87-f7ef-4805-847d-9b9fd58f6de2`) and an ongoing request (`908a0864-2d3a-4aa2-9d6c-6806d36e9d83`) using the existing App Store Connect API access. Apple returned the expected download, discovery, purchase, and subscription report types. A later check of eight relevant report types still found no instances. |
| Brand-first visual | `current/nomva-launch-card.png` is a 1080 × 1350 original Nomva card built from the existing logo and current product claims. It is not represented as an app screenshot. Generator: `build_launch_card.swift`. Visual review completed. |
| Draft copy | `LAUNCH_COPY_2026-09.md` now includes a first post for a dedicated Nomva account, image alt text, a demo storyboard, and follow-up copy. |

## Remaining launch gates

| Item | Current state | Required next step |
| --- | --- | --- |
| App Store Connect payout setup | Unverified. The browser reached Apple's sign-in page; no account session was available. | Account holder signs in; check Paid Apps Agreement, tax, and banking statuses. Do not copy account numbers into this file. |
| Campaign links and baseline | Analytics report requests are active, but no report instances were available immediately after setup. Campaign-link creation still needs an App Store Connect browser session. | Download the first generated reports and record the prior 7/30 days of acquisition, subscriptions, retention, and proceeds; generate channel links if Campaigns is available. |
| Public purchase and recovery | No physical purchase, restore, subscriber reinstall, or expired-access result recorded. The connected physical iPhone currently reports unavailable to `devicectl`. | Complete the device checklist in the plan. A real paid purchase is the owner's action; record the result without payment details. |
| Current app screenshots and clips | The public App Store's six screenshot URLs still reference April 21, 2026 simulator captures. The available 1.6 test screenshot is an empty-day activity fixture, unsuitable as the core meal demo. | Capture the 1.6 meal, correction, day-total, free manual/barcode, and paywall paths on a clean device; replace App Store media through review. |
| Dedicated Nomva Instagram | The personal browser session was signed out. The signup form is open with the public business email `jerry@nerdquad.com`, name Nomva, and `@nomvaapp`; the form showed a valid handle indicator. The password field was cleared. No account has been submitted or created. | Owner enters their birth date and a new password, then reviews and submits Instagram's terms. After signup, add logo, bio, and App Store link; convert to a professional account if useful. |
| Public first post | Draft and image ready; not posted. | After payout, purchase/recovery, media, and account checks pass, publish from the dedicated Nomva account and record the post URL and campaign link. |
| Apple Health/Garmin angle | Physical acceptance remains open. | Keep this angle out of the first campaign until selected-source totals and weight paths pass on device. |

## Current decision

Proceed with **$0 organic spend**. The first published brand asset should be the factual launch card, followed by a real current-build meal demo. Do not reuse the April App Store screenshots or the older custom product page plan as new promotional material. Record dates and source for every metric before judging conversion.
