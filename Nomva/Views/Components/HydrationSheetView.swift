import SwiftUI
import SwiftData

struct HydrationSheetView: View {
    let date: Date

    @Query(sort: \WaterEntry.date, order: .reverse) private var allWaterEntries: [WaterEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss)      private var dismiss
    @AppStorage("water_goal_oz") private var goalOz: Double = 64
    @State private var customAmount: String = ""
    @FocusState private var isCustomFocused: Bool

    private let quickAmounts: [Double] = [4, 8, 12, 16, 20, 32]

    private var cal: Calendar { Calendar.current }
    private var dayStart: Date { cal.startOfDay(for: date) }
    private var dayEnd:   Date { cal.date(byAdding: .day, value: 1, to: dayStart)! }

    private var todayEntries: [WaterEntry] {
        allWaterEntries.filter { $0.date >= dayStart && $0.date < dayEnd }
    }

    private var totalOz: Double {
        todayEntries.reduce(0) { $0 + $1.amountOz }
    }

    private var isToday: Bool { cal.isDateInToday(date) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // ── Progress ring ─────────────────────────────
                    progressHeader

                    // ── Quick add ─────────────────────────────────
                    quickAddSection

                    // ── Custom amount ────────────────────────────
                    customAddSection

                    // ── Goal setting ─────────────────────────────
                    goalSection

                    // ── Today's entries ───────────────────────────
                    if !todayEntries.isEmpty {
                        entriesSection
                    }
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Hydration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: - Subviews

    private var progressHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: min(totalOz / goalOz, 1.0))
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(), value: totalOz)

                VStack(spacing: 2) {
                    Image(systemName: "drop.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("\(Int(totalOz))")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("of \(Int(goalOz)) oz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)

            if totalOz >= goalOz {
                Text("Goal reached!")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Add")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                ForEach(quickAmounts, id: \.self) { oz in
                    Button {
                        addWater(oz: oz)
                    } label: {
                        Text("+\(Int(oz)) oz")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.10))
                            .foregroundColor(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var customAddSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Amount")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 10) {
                HStack {
                    TextField("oz", text: $customAmount)
                        .keyboardType(.decimalPad)
                        .focused($isCustomFocused)
                        .font(.title3.weight(.semibold))
                    Text("oz")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    if let oz = Double(customAmount), oz > 0 {
                        addWater(oz: oz)
                        customAmount = ""
                        isCustomFocused = false
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .disabled(Double(customAmount) == nil || (Double(customAmount) ?? 0) <= 0)
            }
        }
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily Goal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 12) {
                ForEach([48.0, 64.0, 80.0, 96.0, 128.0], id: \.self) { target in
                    Button {
                        goalOz = target
                    } label: {
                        Text("\(Int(target))")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(goalOz == target ? Color.blue : Color(UIColor.secondarySystemBackground))
                            .foregroundColor(goalOz == target ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(spacing: 0) {
                ForEach(Array(todayEntries.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        Image(systemName: "drop.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text("\(Int(entry.amountOz)) oz")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            modelContext.delete(entry)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.body)
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if index < todayEntries.count - 1 {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Actions

    private func addWater(oz: Double) {
        let entry = WaterEntry(amountOz: oz)
        if !isToday {
            // Set the time to noon on the selected date so it lands on the right day
            entry.date = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        }
        modelContext.insert(entry)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
