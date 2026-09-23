# Nomva promotion execution status

Updated September 22, 2026. This records completed work and the evidence still needed before the broad organic launch. Source plan: `LAUNCH_2026-09.md`.

## Complete

| Item | Evidence |
| --- | --- |
| Public landing page and App Store CTA | `https://nomva.nerdquad.com/` serves the updated `server/public/index.html`. On September 23 at 02:18 UTC, the live file SHA-256 matched local `76b52deda164a599938b3a0e9f62b0ebeceb9bc938a2838bf8eb2da8b0985924`. Both Download buttons now use Apple's `launch_site_sep26` campaign URL; the live page exposed both links, the URL resolved to Nomva's App Store listing, and `/health` returned `status: ok` with the food database available. The page has an iPhone App Store banner and uses the original launch card for social previews; the public PNG hash previously matched local `50d7a3dc0b8608c396fffa1c87982f86df5c3e3240e8c6f165e6a7675026d00c`. The prior HTML is backed up as `index.html.backup-20260923T021838Z` on the server. |
| Current public listing | The [US App Store listing](https://apps.apple.com/us/app/nomva/id6762495287) and iTunes public lookup show Nomva 1.6, released September 22, 2026, free with Nomva Pro Monthly listed at $4.99 in the US. The App Store Connect API confirms iOS version 1.6 is `READY_FOR_SALE` with build 46. |
| Subscription product state | The App Store Connect API returned `APPROVED` for `com.nerdquad.nomva.pro.monthly` with a one-month period. Product approval alone does not prove a successful customer purchase; payout setup is checked separately below. |
| Business readiness | App Store Connect setup was checked and cleared September 22. Financial details and the dated baseline are kept locally outside this public repository. |
| Analytics collection | Created a one-time historical snapshot request (`7ba80b87-f7ef-4805-847d-9b9fd58f6de2`) and an ongoing request (`908a0864-2d3a-4aa2-9d6c-6806d36e9d83`) using the existing App Store Connect API access. Apple returned the expected download, discovery, purchase, and subscription report types. A later check of eight relevant report types still found no instances. |
| Campaign links | App Store Connect generated separate URLs for the website and future Nomva Instagram account. The website URL is live in both Download buttons; the Instagram URL is recorded in `CAMPAIGN_LINKS_2026-09.md` for later bio setup. A dated seven- and 30-day baseline was recorded in a local file outside this public GitHub repository. Apple's Campaigns view has no reportable rows yet. |
| Brand-first visual | `current/nomva-launch-card.png` is a 1080 × 1350 original Nomva card built from the existing logo and current product claims. It is not represented as an app screenshot. Generator: `build_launch_card.swift`. Visual review completed. |
| Draft copy | `LAUNCH_COPY_2026-09.md` now includes a first post for a dedicated Nomva account, image alt text, a demo storyboard, and follow-up copy. |
| Current-build media candidates | Built and launched Nomva 1.6 (46) in a clean iPhone 16 / iOS 18.3.1 simulator. Seeded fictional screenshot data with the app's built-in action, then captured five raw 1179 × 2556 screenshots and a 46-second manual food logging walkthrough in `current/`. Visual review confirmed the free catalog match, half-serving calculation, updated daily total, and current Pro paywall. Provenance and limits are in `current/README.md`. |

## Remaining launch gates

| Item | Current state | Required next step |
| --- | --- | --- |
| Missing baseline cells | The seven- and 30-day baseline is captured locally, but Apple suppressed several small acquisition cells and subscription/retention data remains pending. Analytics report requests have no instances yet. | Recheck the historical and ongoing reports when populated; add subscription starts and retention to the private baseline only when Apple reports them. |
| Public purchase and recovery | No physical purchase, restore, subscriber reinstall, or expired-access result recorded. `devicectl` now sees the paired iPhone 17 Pro, but Nomva is not installed on it. iPhone Mirroring timed out while connecting. | Lock the iPhone so Mirroring can connect, install the public App Store build, and complete the device checklist. A real paid purchase is the owner's action; record the result without payment details. |
| App Store screenshots and AI clip | The public App Store's six screenshot URLs still reference April 21, 2026 simulator captures. Five current 1.6 simulator screenshots and one manual-logging clip are captured and packaged, but they are not yet public-build media. No honest AI meal clip is captured because this clean simulator has no Pro entitlement. | Review candidate images at small display size, capture the AI meal and correction on a legitimately entitled device, then replace App Store media through review. |
| Dedicated Nomva Instagram | The personal browser session was signed out. The signup form is open with the public business email `jerry@nerdquad.com`, name Nomva, and `@nomvaapp`; the form showed a valid handle indicator. The password field was cleared. No account has been submitted or created. | Owner enters their birth date and a new password, then reviews and submits Instagram's terms. After signup, add logo, bio, and App Store link; convert to a professional account if useful. |
| Public first post | Draft and image ready; not posted. | After purchase/recovery, media, and account checks pass, publish from the dedicated Nomva account and record the post URL and campaign link. |
| Apple Health/Garmin angle | Physical acceptance remains open. | Keep this angle out of the first campaign until selected-source totals and weight paths pass on device. |
| Nutrition detail copy | A lower Data Coverage card in the public 1.6 app showed internal-sounding text during simulator review. The source copy is polished on this branch, but the public build still needs a future update. | Keep that card out of promotional media until the revised copy ships. |

## Current decision

Proceed with **$0 organic spend**. The first published brand asset should be the factual launch card, followed by a real current-build meal demo. Do not reuse the April App Store screenshots or the older custom product page plan as new promotional material. Record dates and source for every metric before judging conversion.
