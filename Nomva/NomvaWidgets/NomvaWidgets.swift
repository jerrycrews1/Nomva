import AppIntents
import Charts
import SwiftUI
import WidgetKit

struct NomvaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: NomvaWidgetSnapshot
}

struct NomvaSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> NomvaWidgetEntry {
        NomvaWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NomvaWidgetEntry) -> Void) {
        completion(NomvaWidgetEntry(date: .now, snapshot: NomvaWidgetSnapshotStore.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NomvaWidgetEntry>) -> Void) {
        let entry = NomvaWidgetEntry(date: .now, snapshot: NomvaWidgetSnapshotStore.readSnapshot())
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }
}

struct TodaySummaryWidget: Widget {
    let kind = "TodaySummaryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NomvaSnapshotProvider()) { entry in
            TodaySummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Today Summary")
        .description("See calories remaining, macros, and meal progress at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct HydrationWidget: Widget {
    let kind = "HydrationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NomvaSnapshotProvider()) { entry in
            HydrationWidgetView(entry: entry)
        }
        .configurationDisplayName("Hydration")
        .description("Track water progress and add water fast.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct ActivityGoalWidget: Widget {
    let kind = "ActivityGoalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NomvaSnapshotProvider()) { entry in
            ActivityGoalWidgetView(entry: entry)
        }
        .configurationDisplayName("Activity Goal")
        .description("See how activity is shaping your calorie target.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct WeightTrendWidget: Widget {
    let kind = "WeightTrendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NomvaSnapshotProvider()) { entry in
            WeightTrendWidgetView(entry: entry)
        }
        .configurationDisplayName("Weight Trend")
        .description("Keep your latest weight and short trend close at hand.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct QuickLogLauncherWidget: Widget {
    let kind = "QuickLogLauncherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NomvaSnapshotProvider()) { entry in
            QuickLogLauncherWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Log")
        .description("Jump straight into the logging flow you need.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

private struct TodaySummaryWidgetView: View {
    let entry: NomvaWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    private var isRedacted: Bool { redactionReasons.contains(.privacy) }

    var body: some View {
        NomvaWidgetSurface {
            switch family {
            case .systemSmall:
                todaySmall
            case .systemMedium:
                todayMedium
            case .systemLarge:
                todayLarge
            case .accessoryRectangular:
                todayAccessoryRectangular
            default:
                todayMedium
            }
        }
        .widgetURL(NomvaWidgetRoute.todayLog.url)
    }

    private var todaySmall: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)

            if isRedacted {
                Text("Progress available")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(NomvaWidgetPalette.primaryText)
            } else {
                Text(remainingCaloriesValueText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(remainingCaloriesColor)
                    .privacySensitive()
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(isRedacted ? "Tap to view in Nomva" : remainingCaloriesCaption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
                .privacySensitive()
                .lineLimit(1)

            if !isRedacted {
                Text("\(Int(entry.snapshot.today.consumedCalories.rounded())) / \(Int(entry.snapshot.today.adjustedGoalCalories.rounded())) kcal")
                    .font(.caption2)
                    .foregroundStyle(NomvaWidgetPalette.mutedText)
                    .privacySensitive()
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack {
                Label("\(entry.snapshot.today.mealCount)", systemImage: "fork.knife")
                Spacer()
                Label("\(Int(entry.snapshot.hydration.totalOz.rounded())) oz", systemImage: "drop.fill")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NomvaWidgetPalette.secondaryText)
            .privacySensitive()
        }
    }

    private var todayMedium: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's Calories")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NomvaWidgetPalette.secondaryText)
                    if isRedacted {
                        Text("Progress available")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(NomvaWidgetPalette.primaryText)
                    } else {
                        Text(remainingCaloriesText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(remainingCaloriesColor)
                            .privacySensitive()
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(entry.snapshot.today.mealCount) meals")
                    if let lastLoggedAt = entry.snapshot.today.lastLoggedAt {
                        Text(lastLoggedAt.formatted(date: .omitted, time: .shortened))
                    } else {
                        Text("No logs yet")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
                .privacySensitive()
            }

            MacroWidgetBar(label: "Protein", value: entry.snapshot.today.proteinG, goal: entry.snapshot.today.proteinGoalG, tint: .blue)
            MacroWidgetBar(label: "Carbs", value: entry.snapshot.today.carbsG, goal: entry.snapshot.today.carbsGoalG, tint: .green)
            MacroWidgetBar(label: "Fat", value: entry.snapshot.today.fatG, goal: entry.snapshot.today.fatGoalG, tint: .orange)
        }
    }

    private var todayLarge: some View {
        VStack(alignment: .leading, spacing: 16) {
            todayMedium

            Divider()
                .overlay(NomvaWidgetPalette.divider)

            HStack(spacing: 16) {
                summaryBadge(title: "Water", value: "\(Int(entry.snapshot.hydration.totalOz.rounded())) oz", tint: .blue)
                summaryBadge(title: "Meals", value: "\(entry.snapshot.today.mealCount)", tint: .orange)
                summaryBadge(title: "Updated", value: entry.snapshot.lastUpdatedAt.formatted(date: .omitted, time: .shortened), tint: .white.opacity(0.9))
            }

            Text("Open Nomva to add more food, scan a barcode, or review your day.")
                .font(.caption)
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
        }
    }

    private var todayAccessoryRectangular: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
                Text(isRedacted ? "Progress available" : remainingCaloriesText)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(remainingCaloriesColor)
                    .privacySensitive()
                    .monospacedDigit()
            }

            Spacer()

            Text("\(entry.snapshot.today.mealCount) meals")
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
                .privacySensitive()
        }
    }

    private var remainingCaloriesText: String {
        let remaining = entry.snapshot.today.remainingCalories.rounded()
        if remaining >= 0 {
            return "\(Int(remaining)) left"
        }
        return "\(Int(abs(remaining))) over"
    }

    private var remainingCaloriesValueText: String {
        let remaining = entry.snapshot.today.remainingCalories.rounded()
        return "\(Int(abs(remaining)))"
    }

    private var remainingCaloriesCaption: String {
        entry.snapshot.today.remainingCalories >= 0 ? "kcal left" : "kcal over"
    }

    private var remainingCaloriesColor: Color {
        entry.snapshot.today.remainingCalories >= 0 ? NomvaWidgetPalette.calorieAccent : NomvaWidgetPalette.overAccent
    }

    private func summaryBadge(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.mutedText)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(NomvaWidgetPalette.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HydrationWidgetView: View {
    let entry: NomvaWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    private var progress: Double {
        guard entry.snapshot.hydration.goalOz > 0 else { return 0 }
        return min(entry.snapshot.hydration.totalOz / entry.snapshot.hydration.goalOz, 1)
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                accessoryCircular
            case .accessoryRectangular:
                accessoryRectangular
            default:
                NomvaWidgetSurface {
                    switch family {
                    case .systemSmall:
                        smallHydration
                    case .systemMedium:
                        mediumHydration
                    default:
                        mediumHydration
                    }
                }
            }
        }
        .widgetURL(NomvaWidgetRoute.hydration.url)
    }

    private var smallHydration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hydration")
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)

            if redactionReasons.contains(.privacy) {
                Text("Hydration updated")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(NomvaWidgetPalette.primaryText)
            } else {
                Text("\(Int(entry.snapshot.hydration.totalOz.rounded())) / \(Int(entry.snapshot.hydration.goalOz.rounded())) oz")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(NomvaWidgetPalette.primaryText)
                    .privacySensitive()
                    .monospacedDigit()
            }

            ProgressView(value: progress)
                .tint(.blue)

            Spacer(minLength: 0)

            Button(intent: AddWaterIntent(amountOz: 8)) {
                Label("+8 oz", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
    }

    private var mediumHydration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hydration")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NomvaWidgetPalette.secondaryText)
                    Text(redactionReasons.contains(.privacy) ? "Hydration updated" : "\(Int(entry.snapshot.hydration.totalOz.rounded())) / \(Int(entry.snapshot.hydration.goalOz.rounded())) oz")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(NomvaWidgetPalette.primaryText)
                        .privacySensitive()
                        .monospacedDigit()
                }

                Spacer()

                Image(systemName: "drop.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(Color.blue.opacity(0.14))
                    .clipShape(Circle())
            }

            ProgressView(value: progress)
                .tint(.blue)

            HStack(spacing: 10) {
                Button(intent: AddWaterIntent(amountOz: 8)) {
                    Text("+8 oz")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button(intent: AddWaterIntent(amountOz: 12)) {
                    Text("+12 oz")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
            .font(.caption.weight(.semibold))
        }
    }

    private var accessoryCircular: some View {
        Gauge(value: progress) {
            Image(systemName: "drop.fill")
        } currentValueLabel: {
            Text("\(Int(entry.snapshot.hydration.totalOz.rounded()))")
                .privacySensitive()
        }
        .gaugeStyle(.accessoryCircular)
        .tint(.blue)
    }

    private var accessoryRectangular: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hydration")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
                Text(redactionReasons.contains(.privacy) ? "Updated" : "\(Int(entry.snapshot.hydration.totalOz.rounded())) / \(Int(entry.snapshot.hydration.goalOz.rounded())) oz")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NomvaWidgetPalette.primaryText)
                    .privacySensitive()
                    .monospacedDigit()
            }

            Spacer()

            Button(intent: AddWaterIntent(amountOz: 8)) {
                Text("+8")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
    }
}

private struct ActivityGoalWidgetView: View {
    let entry: NomvaWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        NomvaWidgetSurface {
            switch family {
            case .systemSmall:
                smallActivity
            case .accessoryRectangular:
                accessoryActivity
            default:
                mediumActivity
            }
        }
        .widgetURL(NomvaWidgetRoute.goals.url)
    }

    private var smallActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.snapshot.activity.source.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)

            if entry.snapshot.activity.state == .ready {
                Text(redactionReasons.contains(.privacy) ? "Progress available" : activityHeadline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)
                    .privacySensitive()
                    .monospacedDigit()
            } else {
                Text(stateHeadline)
                    .font(.headline.weight(.bold))
            }

            Text(stateSubtitle)
                .font(.caption)
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
                .privacySensitive()
        }
    }

    private var mediumActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity Goal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NomvaWidgetPalette.secondaryText)
                    Text(entry.snapshot.activity.source.displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(NomvaWidgetPalette.primaryText)
                }

                Spacer()

                Image(systemName: entry.snapshot.activity.source == .garmin ? "figure.walk.motion" : "heart.text.square.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if entry.snapshot.activity.state == .ready {
                HStack(spacing: 16) {
                    activityStat(title: "Active", value: redactionReasons.contains(.privacy) ? "Updated" : "\(Int((entry.snapshot.activity.activeCalories ?? entry.snapshot.activity.averageActiveCalories ?? 0).rounded())) kcal")
                    activityStat(title: "Goal Delta", value: goalDeltaText)
                }
            } else {
                Text(stateHeadline)
                    .font(.headline.weight(.semibold))
                Text(stateSubtitle)
                    .font(.caption)
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
            }
        }
    }

    private var accessoryActivity: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.activity.source.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
                Text(entry.snapshot.activity.state == .ready ? goalDeltaText : stateHeadline)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NomvaWidgetPalette.calorieAccent)
                    .privacySensitive()
            }

            Spacer()

            Text(stateHeadline == "Connect" ? "Set up" : stateSubtitle)
                .font(.caption2)
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
                .lineLimit(1)
        }
    }

    private func activityStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.mutedText)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(NomvaWidgetPalette.primaryText)
                .privacySensitive()
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(NomvaWidgetPalette.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activityHeadline: String {
        if let activeCalories = entry.snapshot.activity.activeCalories {
            return "\(Int(activeCalories.rounded())) active"
        }
        if let average = entry.snapshot.activity.averageActiveCalories {
            return "\(Int(average.rounded())) avg"
        }
        return "No data"
    }

    private var goalDeltaText: String {
        let delta = entry.snapshot.activity.goalAdjustmentCalories.rounded()
        if abs(delta) < 1 {
            return "On baseline"
        }
        return delta > 0 ? "+\(Int(delta)) kcal" : "−\(Int(abs(delta))) kcal"
    }

    private var stateHeadline: String {
        switch entry.snapshot.activity.state {
        case .manual:
            return "Manual estimate"
        case .ready:
            return "Ready"
        case .waiting:
            return "Waiting"
        case .setup, .disconnected:
            return "Connect"
        }
    }

    private var stateSubtitle: String {
        switch entry.snapshot.activity.state {
        case .manual:
            return "Choose Apple Health or Garmin in Goals."
        case .ready:
            return goalDeltaText
        case .waiting:
            return "Nomva is waiting for activity data."
        case .setup:
            return "Finish the activity connection."
        case .disconnected:
            return "Tap to connect an activity source."
        }
    }
}

private struct WeightTrendWidgetView: View {
    let entry: NomvaWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                accessoryInline
            case .accessoryRectangular:
                accessoryRectangular
            default:
                NomvaWidgetSurface {
                    switch family {
                    case .systemSmall:
                        smallWeight
                    default:
                        mediumWeight
                    }
                }
            }
        }
        .widgetURL(weightRoute)
    }

    private var weightRoute: URL {
        entry.snapshot.weight.latestWeightLbs == nil ? NomvaWidgetRoute.weight.url : NomvaWidgetRoute.weightLog.url
    }

    private var smallWeight: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weight")
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)

            if let latestWeight = entry.snapshot.weight.latestWeightLbs {
                Text(redactionReasons.contains(.privacy) ? "Trend available" : formattedWeight(latestWeight))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(NomvaWidgetPalette.primaryText)
                    .privacySensitive()
                    .monospacedDigit()

                Text(deltaFromAverageText)
                    .font(.caption)
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
                    .privacySensitive()
            } else {
                Text("No weigh-ins yet")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(NomvaWidgetPalette.primaryText)
                Text("Tap to open the weight log.")
                    .font(.caption)
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
            }
        }
    }

    private var mediumWeight: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weight Trend")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NomvaWidgetPalette.secondaryText)
                    if let latestWeight = entry.snapshot.weight.latestWeightLbs {
                        Text(redactionReasons.contains(.privacy) ? "Trend available" : formattedWeight(latestWeight))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(NomvaWidgetPalette.primaryText)
                            .privacySensitive()
                            .monospacedDigit()
                    } else {
                        Text("No weigh-ins yet")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(NomvaWidgetPalette.primaryText)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(trendLabel)
                    if let lastWeighInAt = entry.snapshot.weight.lastWeighInAt {
                        Text(lastWeighInAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
                .privacySensitive()
            }

            if !entry.snapshot.weight.recentWeightsLbs.isEmpty {
                Chart {
                    ForEach(Array(entry.snapshot.weight.recentWeightsLbs.enumerated()), id: \.offset) { index, value in
                        LineMark(
                            x: .value("Index", index),
                            y: .value("Weight", value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(weightTrendColor)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                .privacySensitive()
            }
        }
    }

    private var accessoryInline: some View {
        Group {
            if let latestWeight = entry.snapshot.weight.latestWeightLbs {
                Text(redactionReasons.contains(.privacy) ? "Weight updated" : "\(formattedWeight(latestWeight)) \(trendGlyph)")
                    .privacySensitive()
            } else {
                Text("Weight log")
            }
        }
    }

    private var accessoryRectangular: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weight")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
                if let latestWeight = entry.snapshot.weight.latestWeightLbs {
                    Text(redactionReasons.contains(.privacy) ? "Trend available" : formattedWeight(latestWeight))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(NomvaWidgetPalette.primaryText)
                        .privacySensitive()
                } else {
                    Text("No entries")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(NomvaWidgetPalette.primaryText)
                }
            }

            Spacer()

            Text(trendLabel)
                .font(.caption2)
                .foregroundStyle(NomvaWidgetPalette.secondaryText)
        }
    }

    private func formattedWeight(_ weightLbs: Double) -> String {
        let unit = entry.snapshot.weight.preferredUnit
        let value = unit == .kg ? weightLbs * 0.453592 : weightLbs
        let suffix = unit == .kg ? "kg" : "lb"
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(suffix)"
    }

    private var trendLabel: String {
        switch entry.snapshot.weight.trend {
        case .down:
            return "Trending down"
        case .up:
            return "Trending up"
        case .steady:
            return "Steady"
        case .unknown:
            return "Building history"
        }
    }

    private var trendGlyph: String {
        switch entry.snapshot.weight.trend {
        case .down:
            return "↓"
        case .up:
            return "↑"
        case .steady:
            return "→"
        case .unknown:
            return "•"
        }
    }

    private var deltaFromAverageText: String {
        guard let delta = entry.snapshot.weight.deltaFromAverageLbs else {
            return "Keep logging to build a trend."
        }
        if abs(delta) < 0.1 {
            return "Right on your 7-day average."
        }
        let direction = delta > 0 ? "above" : "below"
        let deltaText = abs(delta).formatted(.number.precision(.fractionLength(1)))
        return "\(deltaText) lb \(direction) 7-day average"
    }

    private var weightTrendColor: Color {
        switch entry.snapshot.weight.trend {
        case .down:
            return .green
        case .up:
            return .pink
        case .steady, .unknown:
            return .orange
        }
    }
}

private struct QuickLogLauncherWidgetView: View {
    let entry: NomvaWidgetEntry

    var body: some View {
        NomvaWidgetSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Log")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(NomvaWidgetPalette.primaryText)

                Text("Open the exact Nomva flow you need without hunting through tabs.")
                    .font(.caption)
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    launcherButton(title: "AI Chat", systemImage: "sparkles", intent: OpenChatIntent())
                    launcherButton(title: "Add Food", systemImage: "plus.circle", intent: OpenManualSearchIntent())
                    launcherButton(title: "Scan", systemImage: "barcode.viewfinder", intent: OpenBarcodeIntent())
                    launcherButton(title: "Weight", systemImage: "scalemass", intent: OpenWeightLogIntent())
                }
            }
        }
    }

    private func launcherButton<I: AppIntent>(title: String, systemImage: String, intent: I) -> some View {
        Button(intent: intent) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(NomvaWidgetPalette.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(NomvaWidgetPalette.panelFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MacroWidgetBar: View {
    let label: String
    let value: Double
    let goal: Double
    let tint: Color

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(value / goal, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
                Spacer()
                Text("\(Int(value.rounded())) / \(Int(goal.rounded())) g")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(NomvaWidgetPalette.secondaryText)
                    .privacySensitive()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(NomvaWidgetPalette.trackFill)
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 6)
        }
    }
}

private struct NomvaWidgetSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .containerBackground(for: .widget) {
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.14, blue: 0.11),
                        Color(red: 0.24, green: 0.18, blue: 0.12),
                        Color(red: 0.36, green: 0.23, blue: 0.13)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

private enum NomvaWidgetPalette {
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.74)
    static let mutedText = Color.white.opacity(0.6)
    static let panelFill = Color.white.opacity(0.09)
    static let trackFill = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.14)
    static let calorieAccent = Color(red: 1.0, green: 0.58, blue: 0.18)
    static let overAccent = Color(red: 1.0, green: 0.42, blue: 0.56)
}
