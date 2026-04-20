import SwiftUI
import Charts

// MARK: - Weight Insights Section (Premium-gated)

struct WeightInsightsSection: View {
    let insight: WeightInsight
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Signal badge + headline
            trendHeader

            // Velocity chart (last 30 days)
            if !insight.dataPoints.isEmpty {
                velocityChart
            }

            // Plateau warning banner
            if let warning = insight.plateauWarning {
                plateauBanner(warning)
            }

            // Stats row
            if insight.signal != .insufficient {
                statsRow
            }
        }
        .nomvaCard(.standard, padding: NomvaTheme.standardCardPadding)
    }

    // MARK: - Trend Header

    private var trendHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                signalBadge
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(NomvaTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(NomvaTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Text(insight.headline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signalBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: insight.signal.icon)
                .font(.caption.weight(.bold))
            Text(insight.signal.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(signalColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(signalColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private var signalColor: Color {
        switch insight.signal {
        case .losing:         return .green
        case .losingSlowing:  return .yellow
        case .plateau:        return .orange
        case .gaining:        return .red
        case .gainingSlowing: return .yellow
        case .insufficient:   return .secondary
        }
    }

    // MARK: - Velocity Chart

    private var velocityChart: some View {
        let recent = Array(insight.dataPoints.suffix(30))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Fat Loss Velocity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart {
                // Zero reference line (drawn once)
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(recent) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Velocity", point.velocity)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                point.velocity < 0 ? Color.green.opacity(0.25) : Color.red.opacity(0.25),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Velocity", point.velocity)
                    )
                    .foregroundStyle(point.velocity < 0 ? Color.green : Color.red)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYAxisLabel("lbs/day")
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                }
            }
            .frame(height: 150)
        }
        .padding(.top, 4)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 12) {
            InsightStat(
                title: "Weekly Rate",
                value: String(format: "%+.1f", convertWeight(insight.weeklyRate)),
                detail: unit == .lbs ? "lbs/wk" : "kg/wk",
                tint: insight.weeklyRate < 0 ? .green : (insight.weeklyRate > 0.05 ? .red : .secondary)
            )
            InsightStat(
                title: "Smoothed",
                value: String(format: "%.1f", convertWeight(insight.smoothedWeight)),
                detail: unit == .lbs ? "lbs" : "kg",
                tint: .primary
            )
            InsightStat(
                title: "Decel. Days",
                value: "\(insight.consecutiveDecelerationDays)",
                detail: insight.consecutiveDecelerationDays >= 3 ? "watch" : "ok",
                tint: insight.consecutiveDecelerationDays >= 3 ? .orange : .green
            )
        }
    }

    // MARK: - Plateau Banner

    private func plateauBanner(_ warning: PlateauWarning) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: warning.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.title3)
                .foregroundStyle(warning.severity == .warning ? Color.orange : Color.yellow)

            VStack(alignment: .leading, spacing: 4) {
                Text(warning.severity == .warning ? "Plateau Prediction" : "Heads Up")
                    .font(.subheadline.weight(.semibold))
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(warning.severity == .warning
                      ? Color.orange.opacity(0.08)
                      : Color.yellow.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(warning.severity == .warning
                        ? Color.orange.opacity(0.2)
                        : Color.yellow.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func convertWeight(_ lbs: Double) -> Double {
        unit == .lbs ? lbs : lbs * 0.453592
    }
}

// MARK: - Stat Tile

private struct InsightStat: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint == .primary ? .primary : tint)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(tint.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Insufficient Data Card

struct WeightInsightsInsufficientCard: View {
    let entryCount: Int
    let minimumRequired: Int

    private var progress: Double {
        min(1.0, Double(entryCount) / Double(minimumRequired))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weight Insights")
                        .font(.headline)
                    Text("Building your trend data…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(NomvaTheme.accent)
                Text("\(entryCount) of \(minimumRequired) days logged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Nomva needs at least \(minimumRequired) days of weight data to calculate trends, velocity, and plateau predictions. Keep logging daily!")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
    }
}

// MARK: - Premium Teaser Card

struct WeightInsightsTeaser: View {
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Weight Insights")
                            .font(.headline)
                        NomvaTag(text: "PRO", tint: NomvaTheme.accent)
                    }
                    Text("Predict plateaus before they happen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(NomvaTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(NomvaTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                featureRow(icon: "chart.line.uptrend.xyaxis", text: "Fat loss velocity chart — see the real trend behind daily noise")
                featureRow(icon: "exclamationmark.triangle", text: "Plateau early warnings — know 7–10 days before the scale stalls")
                featureRow(icon: "gauge.with.needle", text: "EWMA smoothing — scientifically filter out water weight swings")
            }

            Button(action: onUpgrade) {
                Text("Unlock with Nomva Pro")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(NomvaTheme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .nomvaCard(.standard, padding: NomvaTheme.standardCardPadding)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaTheme.accent)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
