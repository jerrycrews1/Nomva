import Foundation

// MARK: - Weight Analytics Engine
//
// Implements signal processing on raw weight data:
//   1. Linear interpolation for missing days
//   2. Exponentially Weighted Moving Average (EWMA) smoothing
//   3. First derivative (velocity) — rate of weight change
//   4. Second derivative (acceleration) — rate of change of velocity
//   5. Plateau prediction — early warning when loss is decelerating

struct WeightDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let raw: Double        // original weight (lbs)
    let smoothed: Double   // EWMA-smoothed weight (lbs)
    let velocity: Double   // lbs/day change (negative = losing)
    let acceleration: Double // change in velocity
}

enum TrendSignal: Equatable {
    case losing          // velocity < 0, acceleration <= 0 (steady loss)
    case losingSlowing   // velocity < 0, acceleration > 0 (loss decelerating)
    case plateau         // velocity ≈ 0
    case gaining         // velocity > 0, acceleration >= 0 (steady gain)
    case gainingSlowing  // velocity > 0, acceleration < 0 (gain decelerating)
    case insufficient    // not enough data
}

struct WeightInsight {
    let signal: TrendSignal
    let currentVelocity: Double        // lbs/day
    let weeklyRate: Double             // lbs/week (velocity × 7)
    let acceleration: Double           // lbs/day²
    let smoothedWeight: Double         // current smoothed weight (lbs)
    let dataPoints: [WeightDataPoint]  // full processed series
    let plateauWarning: PlateauWarning?
    let consecutiveDecelerationDays: Int
}

struct PlateauWarning {
    let message: String
    let daysUntilPlateau: ClosedRange<Int>
    let severity: Severity

    enum Severity {
        case mild    // 1-2 days of deceleration
        case warning // 3+ days — the "one week warning"
    }
}

struct WeightAnalytics {

    // MARK: - Configuration

    /// EWMA decay factor. 0.15 balances responsiveness with noise reduction.
    let alpha: Double

    /// Minimum entries before computing derivatives (prevents false alarms).
    let minimumEntries: Int

    /// Velocity threshold (lbs/day) below which we call it a plateau.
    let plateauThreshold: Double

    /// How many consecutive deceleration days trigger the warning.
    let decelerationWarningDays: Int

    /// Trailing window (days) for the regression slope that drives the
    /// headline signal, weekly rate, and projection. Tuned by simulation:
    /// 14 days balances responsiveness against daily water-weight noise.
    private let regressionWindowDays = 14

    /// |slope| below this (lbs/day ≈ 0.4 lbs/week) reads as a plateau.
    private let slopePlateauThreshold = 0.06

    /// Slope change between adjacent windows that counts as deceleration.
    private let slopeAccelThreshold = 0.025

    init(
        alpha: Double = 0.15,
        minimumEntries: Int = 14,
        plateauThreshold: Double = 0.02,
        decelerationWarningDays: Int = 3
    ) {
        self.alpha = alpha
        self.minimumEntries = minimumEntries
        self.plateauThreshold = plateauThreshold
        self.decelerationWarningDays = decelerationWarningDays
    }

    // MARK: - Public API

    /// Analyze an array of WeightEntry objects and return the full insight.
    func analyze(entries: [(date: Date, weightLbs: Double)]) -> WeightInsight {
        guard entries.count >= minimumEntries else {
            return WeightInsight(
                signal: .insufficient,
                currentVelocity: 0,
                weeklyRate: 0,
                acceleration: 0,
                smoothedWeight: entries.last?.weightLbs ?? 0,
                dataPoints: [],
                plateauWarning: nil,
                consecutiveDecelerationDays: 0
            )
        }

        // Sort chronologically
        let sorted = entries.sorted { $0.date < $1.date }

        // Step 1: Interpolate missing days to get an even daily series
        let daily = interpolateDailySeries(from: sorted)

        // Step 2: Apply EWMA smoothing
        let smoothed = ewmaSmooth(daily.map(\.weightLbs))

        // Step 3: Compute velocity and acceleration
        var dataPoints: [WeightDataPoint] = []
        for i in daily.indices {
            let v: Double = i > 0 ? smoothed[i] - smoothed[i - 1] : 0
            let a: Double = i > 1 ? (smoothed[i] - smoothed[i - 1]) - (smoothed[i - 1] - smoothed[i - 2]) : 0
            dataPoints.append(WeightDataPoint(
                date: daily[i].date,
                raw: daily[i].weightLbs,
                smoothed: smoothed[i],
                velocity: v,
                acceleration: a
            ))
        }

        guard let last = dataPoints.last else {
            return insufficientResult(entries: entries)
        }

        // Step 4: Headline velocity/acceleration from REGRESSION WINDOWS, not
        // from a single day's EWMA delta. A one-day difference of a smoothed
        // series is dominated by the last raw weigh-in's noise: simulation
        // with a true -0.2 lbs/day trend and normal ±1.2 lb daily water noise
        // showed the single-day classifier calling it "gaining" 14% of the
        // time and detecting a true plateau only 9% of the time. An OLS slope
        // over the trailing 14 smoothed days vs. the prior 14 brings
        // wrong-direction verdicts to ~0% and plateau detection to ~86%, and
        // stabilizes the displayed lbs/week by ~5x. (See
        // reports/retest-2026-08-01/weight-analytics-verification.txt.)
        let smoothedSeries = dataPoints.map(\.smoothed)
        let window = min(regressionWindowDays, smoothedSeries.count)
        let recentSlope = Self.olsSlope(Array(smoothedSeries.suffix(window)))
        let previousSlope: Double
        if smoothedSeries.count >= window * 2 {
            let priorSlice = Array(smoothedSeries.suffix(window * 2).prefix(window))
            previousSlope = Self.olsSlope(priorSlice)
        } else {
            previousSlope = recentSlope
        }
        let slopeAcceleration = recentSlope - previousSlope

        // Step 5: Count consecutive deceleration days using windowed slopes
        let consecDays = consecutiveDecelerationDays(smoothed: smoothedSeries)

        // Step 6: Determine trend signal from the regression slopes
        let signal = classifySignal(slope: recentSlope, slopeAcceleration: slopeAcceleration)

        // Step 7: Check for plateau warning
        let warning = plateauWarning(
            signal: signal,
            velocity: recentSlope,
            acceleration: slopeAcceleration,
            consecutiveDays: consecDays
        )

        return WeightInsight(
            signal: signal,
            currentVelocity: recentSlope,
            weeklyRate: recentSlope * 7,
            acceleration: slopeAcceleration,
            smoothedWeight: last.smoothed,
            dataPoints: dataPoints,
            plateauWarning: warning,
            consecutiveDecelerationDays: consecDays
        )
    }

    // MARK: - Projection

    struct Projection {
        let slopeLbsPerDay: Double
        let daysAhead: Int
        let projectedWeightLbs: Double
        let targetDate: Date
    }

    /// Where the user is on track to be in `daysAhead` days, extending the
    /// regression trend of the smoothed series. Returns nil until there is
    /// enough real data for the extrapolation to mean something: at least 5
    /// logged days spanning at least 10 calendar days, and a sane slope.
    func projection(
        entries: [(date: Date, weightLbs: Double)],
        daysAhead: Int
    ) -> Projection? {
        let cal = Calendar.current
        let loggedDays = Set(entries.map { cal.startOfDay(for: $0.date) })
        guard loggedDays.count >= 5,
              let firstDay = loggedDays.min(),
              let lastDay = loggedDays.max(),
              let span = cal.dateComponents([.day], from: firstDay, to: lastDay).day,
              span >= 10
        else { return nil }

        let sorted = entries.sorted { $0.date < $1.date }
        let daily = interpolateDailySeries(from: sorted)
        let smoothed = ewmaSmooth(daily.map(\.weightLbs))
        guard smoothed.count >= 2, let lastValue = smoothed.last else { return nil }

        let window = min(regressionWindowDays, smoothed.count)
        let slope = Self.olsSlope(Array(smoothed.suffix(window)))
        // A slope beyond half a pound per day sustained is either bad data or
        // a medical situation — either way, extrapolating it is irresponsible.
        guard abs(slope) <= 0.5 else { return nil }

        let target = cal.date(byAdding: .day, value: daysAhead, to: lastDay) ?? lastDay
        return Projection(
            slopeLbsPerDay: slope,
            daysAhead: daysAhead,
            projectedWeightLbs: lastValue + slope * Double(daysAhead),
            targetDate: target
        )
    }

    /// Ordinary least-squares slope of evenly spaced (daily) values, in units
    /// per day. Zero for degenerate input.
    static func olsSlope(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        let meanX = Double(n - 1) / 2
        let meanY = values.reduce(0, +) / Double(n)
        var sxy = 0.0
        var sxx = 0.0
        for (i, y) in values.enumerated() {
            let dx = Double(i) - meanX
            sxy += dx * (y - meanY)
            sxx += dx * dx
        }
        return sxx > 0 ? sxy / sxx : 0
    }

    // MARK: - Interpolation

    /// Fill in missing calendar days between entries using linear interpolation.
    private func interpolateDailySeries(from entries: [(date: Date, weightLbs: Double)]) -> [(date: Date, weightLbs: Double)] {
        guard entries.count >= 2 else { return entries }

        let cal = Calendar.current
        var result: [(date: Date, weightLbs: Double)] = []

        // Group by calendar day, taking the average if multiple entries per day
        var byDay: [Date: [Double]] = [:]
        for entry in entries {
            let day = cal.startOfDay(for: entry.date)
            byDay[day, default: []].append(entry.weightLbs)
        }

        let sortedDays = byDay.keys.sorted()
        guard let firstDay = sortedDays.first, let lastDay = sortedDays.last else {
            return entries
        }

        // Build a daily average lookup
        var dailyAvg: [Date: Double] = [:]
        for (day, weights) in byDay {
            dailyAvg[day] = weights.reduce(0, +) / Double(weights.count)
        }

        // Walk day by day, interpolating gaps
        var currentDay = firstDay
        while currentDay <= lastDay {
            if let weight = dailyAvg[currentDay] {
                result.append((date: currentDay, weightLbs: weight))
            } else {
                // Find the nearest known day before and after
                let before = findNearest(before: currentDay, in: dailyAvg, cal: cal)
                let after = findNearest(after: currentDay, in: dailyAvg, cal: cal)

                if let (bDate, bWeight) = before, let (aDate, aWeight) = after {
                    let totalDays = Double(cal.dateComponents([.day], from: bDate, to: aDate).day ?? 1)
                    let elapsed = Double(cal.dateComponents([.day], from: bDate, to: currentDay).day ?? 0)
                    let fraction = totalDays > 0 ? elapsed / totalDays : 0
                    let interpolated = bWeight + fraction * (aWeight - bWeight)
                    result.append((date: currentDay, weightLbs: interpolated))
                } else if let (_, bWeight) = before {
                    result.append((date: currentDay, weightLbs: bWeight))
                } else if let (_, aWeight) = after {
                    result.append((date: currentDay, weightLbs: aWeight))
                }
            }
            currentDay = cal.date(byAdding: .day, value: 1, to: currentDay)!
        }

        return result
    }

    private func findNearest(before target: Date, in lookup: [Date: Double], cal: Calendar) -> (Date, Double)? {
        var day = cal.date(byAdding: .day, value: -1, to: target)!
        for _ in 0..<60 {
            if let w = lookup[day] { return (day, w) }
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return nil
    }

    private func findNearest(after target: Date, in lookup: [Date: Double], cal: Calendar) -> (Date, Double)? {
        var day = cal.date(byAdding: .day, value: 1, to: target)!
        for _ in 0..<60 {
            if let w = lookup[day] { return (day, w) }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return nil
    }

    // MARK: - EWMA Smoothing

    /// S_t = α · W_t + (1 − α) · S_{t-1}
    private func ewmaSmooth(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        var smoothed: [Double] = [values[0]]
        for i in 1..<values.count {
            let s = alpha * values[i] + (1 - alpha) * smoothed[i - 1]
            smoothed.append(s)
        }
        return smoothed
    }

    // MARK: - Signal Classification

    private func classifySignal(slope: Double, slopeAcceleration: Double) -> TrendSignal {
        if abs(slope) < slopePlateauThreshold {
            return .plateau
        }
        if slope < 0 {
            return slopeAcceleration > slopeAccelThreshold ? .losingSlowing : .losing
        }
        return slopeAcceleration < -slopeAccelThreshold ? .gainingSlowing : .gaining
    }

    // MARK: - Deceleration Counter

    /// Counts how many consecutive recent days the windowed regression slope
    /// has been decelerating (same trend direction, magnitude shrinking).
    /// Uses the same windowed slopes as the headline signal so a single noisy
    /// weigh-in cannot start or break the streak.
    private func consecutiveDecelerationDays(smoothed: [Double]) -> Int {
        let window = min(regressionWindowDays, smoothed.count)
        guard window >= 4, smoothed.count >= window + 1 else { return 0 }

        func slopeEnding(at index: Int) -> Double {
            let start = max(0, index - window + 1)
            return Self.olsSlope(Array(smoothed[start...index]))
        }

        var count = 0
        var index = smoothed.count - 1
        while index > window {
            let today = slopeEnding(at: index)
            let yesterday = slopeEnding(at: index - 1)

            let isDecelerating: Bool
            if today < -slopePlateauThreshold {
                isDecelerating = today > yesterday + 1e-9
            } else if today > slopePlateauThreshold {
                isDecelerating = today < yesterday - 1e-9
            } else {
                break // already at plateau
            }

            if isDecelerating {
                count += 1
                index -= 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - Plateau Warning

    private func plateauWarning(
        signal: TrendSignal,
        velocity: Double,
        acceleration: Double,
        consecutiveDays: Int
    ) -> PlateauWarning? {
        // Only warn when velocity is negative (losing) and acceleration is positive (slowing)
        // or velocity is positive (gaining) and acceleration is negative (slowing)
        guard signal == .losingSlowing || signal == .gainingSlowing else {
            return nil
        }

        guard consecutiveDays >= 1 else { return nil }

        if consecutiveDays >= decelerationWarningDays {
            let verb = signal == .losingSlowing ? "weight loss" : "weight gain"
            return PlateauWarning(
                message: "Your \(verb) is slowing down. Based on current trends, you may hit a plateau within 7 to 10 days.",
                daysUntilPlateau: 7...10,
                severity: .warning
            )
        } else {
            let verb = signal == .losingSlowing ? "loss" : "gain"
            return PlateauWarning(
                message: "Your rate of \(verb) has started to slow over the last \(consecutiveDays) day\(consecutiveDays == 1 ? "" : "s"). This is normal — keep it up.",
                daysUntilPlateau: 10...14,
                severity: .mild
            )
        }
    }

    // MARK: - Helpers

    private func insufficientResult(entries: [(date: Date, weightLbs: Double)]) -> WeightInsight {
        WeightInsight(
            signal: .insufficient,
            currentVelocity: 0,
            weeklyRate: 0,
            acceleration: 0,
            smoothedWeight: entries.last?.weightLbs ?? 0,
            dataPoints: [],
            plateauWarning: nil,
            consecutiveDecelerationDays: 0
        )
    }
}

// MARK: - Display Helpers

extension TrendSignal {
    var label: String {
        switch self {
        case .losing:         return "Losing"
        case .losingSlowing:  return "Loss Slowing"
        case .plateau:        return "Plateau"
        case .gaining:        return "Gaining"
        case .gainingSlowing: return "Gain Slowing"
        case .insufficient:   return "Building Data"
        }
    }

    var icon: String {
        switch self {
        case .losing:         return "arrow.down.right"
        case .losingSlowing:  return "arrow.right"
        case .plateau:        return "minus"
        case .gaining:        return "arrow.up.right"
        case .gainingSlowing: return "arrow.right"
        case .insufficient:   return "chart.bar.doc.horizontal"
        }
    }

}

extension WeightInsight {
    /// User-facing summary sentence.
    var headline: String {
        switch signal {
        case .insufficient:
            return "Log at least 14 days of weight data to unlock trend predictions."
        case .losing:
            return "You're losing about \(formattedWeekly) per week — steady progress."
        case .losingSlowing:
            return "Still losing, but the pace is easing up."
        case .plateau:
            return "Your weight has been holding steady."
        case .gaining:
            return "You're gaining about \(formattedWeekly) per week."
        case .gainingSlowing:
            return "Still gaining, but the pace is tapering off."
        }
    }

    private var formattedWeekly: String {
        String(format: "%.1f lbs", abs(weeklyRate))
    }
}
