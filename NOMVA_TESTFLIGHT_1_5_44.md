# Nomva 1.5 (44): food corrections and portion editing

## Delivery

The backend correction fixes are deployed at https://nomva.nerdquad.com. Production health passed with 804,289 food rows. All four changed server files match the candidate; rollback files are in `/home/ubuntu/nomva-api/deploy-backups/20260914-portion-44`.

The signed archive is `/Users/jerrycrews/Library/Developer/Xcode/Archives/2026-09-14/Nomva 1.5-44.xcarchive`. Both app and widget are version 1.5, build 44. App Attest is production and HealthKit entitlements are present. Executable SHA256: `749c622cde258428c4400891529c41331c32077ef6c109afdcc9c4e526fadf4e`.

**TestFlight upload remains blocked.** Xcode export returned `Failed to Use Accounts` on September 14; native UI access confirmed the Mac is locked. Unlock the Mac, then upload this archive with `/Users/jerrycrews/Library/Caches/NomvaValidation-44/TestFlightExport.plist`. No rebuild is needed. Apple processing, tester availability and installation of build 44 are not yet verified.

## What changed

- Explicit corrections such as “I had the whole bottle of Gatorade not just 12 oz” reach edit handling before the “I had” food-add shortcut. A plain new consumption report remains an addition.
- A unique named existing entry can be selected locally. Multiple matching entries require disambiguation.
- Compatible portion conversions use the saved nutrition basis. A 12 fl oz serving in a known 28 oz bottle scales by 28/12, updates the same entry, and leaves neighboring drinks alone. A stated new size takes precedence; a missing container size requires clarification.
- Both chat and the manual editor use the existing saved nutrition when grams are unavailable. They preserve all nutrients, including optional unknown values, and never invent a gram weight. Repeated edits preserve the physical portion description so the next correction uses the correct basis.
- The editor hides the unavailable grams field, validates the amount, avoids reciprocal text-field update loops, explicitly saves, and preserves the old values on a save failure. A meal-only save preserves the original portion wording and nutrition.
- A model response that asks for missing information while expressing uncertainty cannot also authorize an edit.

These changes operate on local food records. The existing Apple Health weight bridge and storage policy are retained.

## Verification

| Check | Result |
| --- | --- |
| Final iOS core tests | 46/46 passed |
| Full UI suite | 8/8 passed |
| Final rebuilt app, exact screenshot flow | Passed again with all 46 core tests: 47/47 total |
| Final server tests | 181/181 passed |
| Live screenshot-related language cases | 8/8 cases, 10/10 checks passed; uses the same response validation as the server and retains raw model responses |
| Current generated held-out validation | 98.2/100; 168/171 checks, 97/100 completely passing cases |
| Production deployment | Health passed; four deployed file hashes match the tested source; 4/4 authenticated public API checks passed |
| Archive inputs | 18 changed source/configuration/test files matched the validation checkout |

The UI regression opens the fixed-serving drink, verifies 80 calories rather than zero, changes its amount and saves 160 calories, reopens it, sends the exact whole-bottle correction through chat, confirms one entry remains, and reopens a 186.7-calorie preview. The core regression also includes the neighboring Celsius and Coke Zero entries and verifies their totals do not change. This arithmetic scales the fixture's saved 80-calorie/12-fl-oz nutrition; it is not an independent verification of a manufacturer label.

Evidence and the verified screenshot are under `reports/reliability-audit-2026-09-14/portion-release-44/`. The final test bundle is `/tmp/nomva-44-release-check.xcresult`. Simulator tests do not prove physical-camera behavior or HealthKit delivery.

## Remaining review items

The current live evaluation still has three search-query checks below expectation: one loose restaurant-fries query and two spinach queries. Check actual retrieved foods and portions as well as query wording before treating these as resolved. The older checked-in 200-case file also ran and scored 92.3/100; it is retained as a failed run, not counted as a release pass. Its expectations differ from the maintained generator, including requiring “potato” in a restaurant query and a one-cup spinach default where the current contract leaves an unspecified amount unresolved. Evaluation coverage needs consolidation to prevent contradictory fixtures and misleading aggregate scores.

Adding production failures to focused, outcome-based regression checks follows [OpenAI's evaluation workflow](https://developers.openai.com/api/docs/guides/evaluation-best-practices#design-your-eval-process). The screenshot flow is now tested through actual local persistence, not only against model output.
