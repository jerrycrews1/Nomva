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

        let velocity = last.velocity
        let acceleration = last.acceleration

        // Step 4: Count consecutive deceleration days
        let consecDays = consecutiveDecelerationDays(from: dataPoints)

        // Step 5: Determine trend signal
        let signal = classifySignal(velocity: velocity, acceleration: acceleration)

        // Step 6: Check for plateau warning
        let warning = plateauWarning(
            signal: signal,
            velocity: velocity,
            acceleration: acceleration,
            consecutiveDays: consecDays
        )

        return WeightInsight(
            signal: signal,
            currentVelocity: velocity,
            weeklyRate: velocity * 7,
            acceleration: acceleration,
            smoothedWeight: last.smoothed,
            dataPoints: dataPoints,
            plateauWarning: warning,
            consecutiveDecelerationDays: consecDays
        )
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

    private func classifySignal(velocity: Double, acceleration: Double) -> TrendSignal {
        if abs(velocity) < plateauThreshold {
            return .plateau
        }
        if velocity < 0 {
            return acceleration > plateauThreshold / 2 ? .losingSlowing : .losing
        }
        // velocity > 0
        return acceleration < -(plateauThreshold / 2) ? .gainingSlowing : .gaining
    }

    // MARK: - Deceleration Counter

    private func consecutiveDecelerationDays(from points: [WeightDataPoint]) -> Int {
        guard points.count >= 3 else { return 0 }

        var count = 0
        // Walk backwards from the most recent point
        for i in stride(from: points.count - 1, through: 2, by: -1) {
            let velocity = points[i].velocity
            let acceleration = points[i].acceleration

            // "Decelerating loss" = still losing (v < 0) but acceleration > 0
            // "Decelerating gain" = still gaining (v > 0) but acceleration < 0
            let isDecelerating: Bool
            if velocity < -plateauThreshold {
                isDecelerating = acceleration > 0
            } else if velocity > plateauThreshold {
                isDecelerating = acceleration < 0
            } else {
                break // at plateau already
            }

            if isDecelerating {
                count += 1
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
