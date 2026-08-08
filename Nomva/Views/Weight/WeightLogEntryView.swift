import SwiftUI
import SwiftData

struct WeightLogEntryView: View {
    var existingEntry: WeightEntry? = nil

    @Query(sort: \WeightEntry.date, order: .reverse) private var allEntries: [WeightEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss)      private var dismiss
    @AppStorage("weight_unit")   private var unitRaw = WeightUnit.lbs.rawValue

    /// Source of truth: display string (e.g. "174.5")
    @State private var weightText: String
    @State private var logDate: Date
    @State private var note: String
    @State private var didApplyDefault = false
    @State private var isSaving = false
    @State private var savedNewEntry: WeightEntry?
    @State private var saveMessage: String?
    @FocusState private var isWeightFocused: Bool

    init(existingEntry: WeightEntry? = nil) {
        self.existingEntry = existingEntry
        if let existing = existingEntry {
            _weightText = State(initialValue: String(format: "%.1f", existing.weightLbs))
        } else {
            // Start blank — onAppear will fill from the last known entry
            _weightText = State(initialValue: "")
        }
        _logDate    = State(initialValue: existingEntry?.date ?? .now)
        _note       = State(initialValue: existingEntry?.note ?? "")
    }

    private var unit:      WeightUnit { WeightUnit(rawValue: unitRaw) ?? .lbs }
    private var isEditing: Bool       { existingEntry != nil }

    /// Parse the text as a weight in the current unit, converted to lbs.
    private var parsedLbs: Double? {
        guard let val = Double(weightText), val > 0 else { return nil }
        return unit == .lbs ? val : val / 0.453592
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Hero weight input ──────────────────────────────────────
                VStack(spacing: 6) {
                    Text(isEditing ? "Edit Entry" : "Log Weight")
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.8)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        TextField(unit == .lbs ? "lbs" : "kg", text: $weightText)
                            .keyboardType(.decimalPad)
                            .focused($isWeightFocused)
                            .font(.system(size: 72, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                            // Validate: only digits + at most one "." + max 1 decimal place
                            .onChange(of: weightText) { _, new in
                                weightText = sanitiseWeightInput(new)
                            }

                        Text(unit == .lbs ? "lbs" : "kg")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 10)
                    }

                    // Unit toggle pills
                    HStack(spacing: 8) {
                        ForEach([WeightUnit.lbs, WeightUnit.kg], id: \.self) { u in
                            Button {
                                switchUnit(to: u)
                            } label: {
                                Text(u == .lbs ? "lbs" : "kg")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(unit == u ? NomvaTheme.accentFill : Color(.systemGray5))
                                    .foregroundStyle(unit == u ? NomvaTheme.onAccent : Color.secondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color(.systemGroupedBackground))

                // ── Date + Note ────────────────────────────────────────────
                List {
                    Section {
                        DatePicker(
                            "Date & Time",
                            selection: $logDate,
                            in: ...Date.now,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }

                    Section {
                        HStack {
                            Image(systemName: "note.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField("Note (optional)", text: $note)
                        }
                    } footer: {
                        Text("e.g. Morning, post-workout, after meal")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(parsedLbs != nil ? NomvaTheme.accent : Color.secondary)
                        .disabled(parsedLbs == nil || isSaving)
                }
            }
            .alert("Weight Saved", isPresented: Binding(
                get: { saveMessage != nil },
                set: { if !$0 { saveMessage = nil } }
            )) {
                Button("Done") { dismiss() }
                Button("Try Apple Health Again") {
                    saveMessage = nil
                }
            } message: {
                Text(saveMessage ?? "")
            }
            .onAppear {
                // For new entries, pre-fill with the most recent weight
                if existingEntry == nil, !didApplyDefault {
                    didApplyDefault = true
                    if let last = allEntries.first {
                        let displayValue = unit == .lbs ? last.weightLbs : last.weightLbs * 0.453592
                        weightText = String(format: "%.1f", displayValue)
                    }
                }
                // Auto-focus the weight field so the keyboard opens immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isWeightFocused = true
                }
            }
        }
    }

    // MARK: - Helpers

    /// Strip anything that isn't a digit or decimal point, and limit to 1 decimal place.
    private func sanitiseWeightInput(_ input: String) -> String {
        // Keep only digits and "."
        let filtered = input.filter { $0.isNumber || $0 == "." }
        // Split on "." — allow at most one decimal point
        let parts = filtered.components(separatedBy: ".")
        if parts.count <= 1 { return filtered }            // no decimal point yet
        let intPart  = parts[0]
        let fracPart = String(parts[1...].joined().prefix(1))   // max 1 decimal digit
        return intPart + "." + fracPart
    }

    /// Convert the displayed value when the user toggles lbs ↔ kg.
    private func switchUnit(to newUnit: WeightUnit) {
        guard newUnit != unit, let lbs = parsedLbs else {
            unitRaw = newUnit.rawValue
            return
        }
        let converted = newUnit == .lbs ? lbs : lbs * 0.453592
        unitRaw     = newUnit.rawValue
        weightText  = String(format: "%.1f", converted)
    }

    @MainActor
    private func save() async {
        guard let lbs = parsedLbs else { return }
        isSaving = true
        defer { isSaving = false }

        let entry: WeightEntry
        if let existingEntry {
            entry = existingEntry
            entry.weightLbs = lbs
            entry.date      = logDate
            entry.note      = note.isEmpty ? nil : note
        } else if let savedNewEntry {
            entry = savedNewEntry
            entry.weightLbs = lbs
            entry.date = logDate
            entry.note = note.isEmpty ? nil : note
        } else {
            let newEntry = WeightEntry(
                date:      logDate,
                weightLbs: lbs,
                note:      note.isEmpty ? nil : note
            )
            modelContext.insert(newEntry)
            savedNewEntry = newEntry
            entry = newEntry
        }

        do {
            try modelContext.save()
        } catch {
            saveMessage = "Nomva couldn't save this weigh-in: \(error.localizedDescription)"
            return
        }

        do {
            try await WeightSyncCoordinator.exportToAppleHealth(entry, in: modelContext)
        } catch {
            saveMessage = "The weigh-in is safely stored in Nomva, but Apple Health could not be updated. \(error.localizedDescription)"
            return
        }
        dismiss()
    }
}
