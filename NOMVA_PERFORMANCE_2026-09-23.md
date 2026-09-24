# Nomva navigation performance test — 2026-09-23

## Setup

- iPhone 17 Pro simulator, iOS 26.5, Xcode Debug build from `322b8c5` plus the current working-tree changes.
- Isolated in-memory fixture: 365 days, 1,095 food entries, 365 weight entries, and 730 chat messages. No personal store was used.
- Automated four-tab cycle repeated four times, then Add Food, Weight chart 1Y/30D, Log Weight, and Settings Goals.
- One save alert appeared at launch in the unsigned simulator build and was dismissed before timing. The installed test app has no App Group container; this alert is not evidence of a signed-device save failure.

## Findings

The baseline Time Profiler trace recorded six Nomva main-thread hangs longer than 250 ms during 32 seconds of repeated navigation. The hangs lasted 267–506 ms. In that trace, 2,234 of 7,174 main-thread CPU samples included `WeightLoggingView.rollingAverageSeries`, and 2,490 included `WeightLoggingView.chartData`. The seven-day average rebuilt `chartData` for every point, and the chart repeatedly requested both computed properties while rendering.

The Weight chart now builds one snapshot per view update and calculates the seven-day average with a sliding window. In the 48-second post-change trace of the same navigation cycle, Nomva had **zero** main-thread hangs over 250 ms. The rolling-average path appeared in 1 of 6,917 main-thread CPU samples; `chartData` appeared in 27.

| Warm tab switch | Baseline median | After median |
| --- | ---: | ---: |
| Weight | 2.90 s | 2.90 s |
| Settings | 3.39 s | 2.96 s |
| AI Chat | 2.95 s | 2.93 s |
| Log | 3.05 s | 3.04 s |

These XCUITest times include event synthesis, app-idle waits, and a roughly one-second accessibility existence poll. They are useful for regression comparison, not direct touch-to-frame latency. The CPU trace is the stronger evidence for the removed stalls.

After the change, button paths completed in the same harness: Add Food 1.58 s, Weight 1Y 1.44 s, Weight 30D 1.48 s, Log Weight 1.48 s, and Settings Goals 2.38 s. All destination checks passed.

## Verification and limits

- The final performance UI test passed: 1 test, 0 failures (`/tmp/NomvaPerfButtonsAfter.xcresult`).
- `git diff --check` passed.
- Instruments' Animation Hitches template does not support this simulator. Time Profiler's main-thread hang detection was used instead.
- The physical iPhone was unavailable to this Mac during testing. Real-device frame pacing, HealthKit/Garmin activity, and the installed public build were not measured here.
