import SwiftUI
import SwiftData

private enum MealDropLayout {
    static let coordinateSpace = "DailyLogMealDropSpace"
}

private struct MealDropFramePreferenceKey: PreferenceKey {
    static let defaultValue: [MealCategory: CGRect] = [:]

    static func reduce(
        value: inout [MealCategory: CGRect],
        nextValue: () -> [MealCategory: CGRect]
    ) {
        for (meal, frame) in nextValue() {
            value[meal] = value[meal].map { $0.union(frame) } ?? frame
        }
    }
}

private extension View {
    func reportsDropFrame(for meal: MealCategory) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MealDropFramePreferenceKey.self,
                    value: [meal: proxy.frame(in: .named(MealDropLayout.coordinateSpace))]
                )
            }
        }
    }
}

struct DailyLogView: View {
    @Query(sort: \FoodEntry.date) private var allEntries: [FoodEntry]
    @Query(sort: \MealTemplate.createdAt, order: .reverse) private var mealTemplates: [MealTemplate]
    @Query                        private var goals: [DailyGoal]
    @Environment(\.modelContext)  private var modelContext
    @Environment(\.undoManager)   private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var garminManager: GarminManager
    @EnvironmentObject private var routeCenter: NomvaRouteCenter
    @AppStorage("goal_activity_source") private var activitySourceRaw = GoalActivitySource.manual.rawValue
    @AppStorage("goal_activity_reference_active_calories") private var activityReferenceActiveCalories = 0.0

    @State private var selectedDate      = Date.now
    @State private var selectedEntry:    FoodEntry? = nil
    @State private var showCustomFoodCreate = false
    @State private var showManualSearch     = false
    @State private var selectedMealForSearch: String? = nil
    @State private var showHydrationSheet      = false
    @State private var deleteFoodEntry: FoodEntry? = nil
    @State private var showDeleteFoodConfirm  = false
    @State private var showNutritionDetail    = false
    @State private var targetedMeal: MealCategory? = nil
    @State private var mealDropFrames: [MealCategory: CGRect] = [:]
    @State private var draggedEntryID: UUID? = nil
    @State private var dragLocation: CGPoint? = nil
    @State private var showMoveError = false
    @State private var moveErrorMessage = ""
    @State private var undoNotice: String? = nil
    @State private var quickAddSource: FoodEntry? = nil
    @State private var showQuickAddMealPicker = false
    @State private var templateToLog: MealTemplate? = nil
    @State private var showTemplateMealPicker = false
    @State private var templateEntriesToSave: [FoodEntry] = []
    @State private var newTemplateName = ""
    @State private var showTemplateNamePrompt = false

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(selectedDate) }
    private var dayStart: Date { cal.startOfDay(for: selectedDate) }
    private var dayEnd:   Date { cal.date(byAdding: .day, value: 1, to: dayStart)! }

    private var selectedDayEntries: [FoodEntry] {
        allEntries.filter { $0.date >= dayStart && $0.date < dayEnd }
    }

    private var currentGoal: DailyGoal { GoalService.currentGoal(from: goals) }
    private var selectedActivitySource: GoalActivitySource {
        GoalActivitySource(rawValue: activitySourceRaw) ?? .manual
    }
    private var garminSummaryForSelectedDate: GarminDailyActivitySummary? {
        garminManager.summary(for: selectedDate)
    }
    private var displayGoal: DailyGoal {
        GoalService.displayGoal(
            base: currentGoal,
            selectedDate: selectedDate,
            activitySource: selectedActivitySource,
            referenceActiveCalories: activityReferenceActiveCalories,
            averageActiveCalories: selectedActivitySource == .garmin
                ? garminManager.averageActiveCalories
                : nil,
            currentDayActiveCalories: selectedActivitySource == .garmin
                ? garminSummaryForSelectedDate?.activeCalories
                : nil,
            completedDayActiveCalories: selectedActivitySource == .garmin
                ? garminSummaryForSelectedDate?.activeCalories
                : nil
        )
    }
    private var activityGoalSnapshot: ActivityGoalSnapshot? {
        guard garminManager.isConnected else { return nil }

        let activeCalories = garminSummaryForSelectedDate?.activeCalories
        let baselineCalories = garminManager.averageActiveCalories
            ?? (activityReferenceActiveCalories > 0 ? activityReferenceActiveCalories : nil)
        let affectsGoal = selectedActivitySource == .garmin
        let earnedCalories = affectsGoal && isToday
            ? GoalService.sameDayActivityCredit(
                currentDayActiveCalories: activeCalories,
                rollingAverageActiveCalories: baselineCalories
            )
            : 0

        return ActivityGoalSnapshot(
            sourceName: "Garmin",
            activeCalories: activeCalories,
            baselineCalories: baselineCalories,
            earnedCalories: earnedCalories,
            goalAdjustmentCalories: affectsGoal ? displayGoal.calories - currentGoal.calories : 0,
            isToday: isToday,
            isSyncing: garminManager.isSyncing,
            affectsGoal: affectsGoal
        )
    }
    private var dayTotals: NutritionTotals { NutritionTotals.from(entries: selectedDayEntries) }

    private var mealSections: [(MealCategory, [FoodEntry])] {
        MealCategory.allCases.map { meal in
            let entries = selectedDayEntries.filter {
                MealCategory(storedValue: $0.meal) == meal
            }
            return (meal, entries)
        }
    }

    private let contentInset: CGFloat = NomvaTheme.contentInset

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                NomvaScreenBackground()

                List {
                    Section {
                        Button {
                            showNutritionDetail = true
                        } label: {
                            MacroRingsView(
                                consumed: dayTotals,
                                goal: displayGoal,
                                showsDetailCue: true,
                                activity: activityGoalSnapshot
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows detailed nutrition, Daily Value context, and trends")
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: NomvaTheme.topCardGap, leading: contentInset, bottom: 8, trailing: contentInset))
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)

                    if isToday {
                        Section {
                            RecentFoodsView { entry in
                                quickAddSource = entry
                                showQuickAddMealPicker = true
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if !selectedDayEntries.isEmpty {
                        ForEach(mealSections, id: \.0) { meal, mealEntries in
                            Section {
                                if mealEntries.isEmpty {
                                    EmptyMealDropZone(isTargeted: targetedMeal == meal)
                                        .listRowInsets(EdgeInsets(top: 2, leading: contentInset, bottom: 2, trailing: contentInset))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .reportsDropFrame(for: meal)
                                } else {
                                    ForEach(mealEntries) { entry in
                                        foodEntryListRow(entry, in: meal)
                                    }
                                }
                            } header: {
                                mealHeader(meal, entries: mealEntries)
                            }
                        }
                    }

                    if selectedDayEntries.isEmpty {
                        Section {
                            emptyLogView
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                                .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if isToday {
                        Section {
                            Button { showHydrationSheet = true } label: {
                                WaterTrackerSection()
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: hydrationTopInset, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                            .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if garminManager.isConnected {
                        Section {
                            garminActivityCard
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                                .listRowSeparator(.hidden)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    Section {
                        UnpersonalizedGoalsBanner()
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: contentInset, bottom: NomvaTheme.sectionGap, trailing: contentInset))
                            .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)

                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await garminManager.refresh(forceSync: true)
                }
                .coordinateSpace(name: MealDropLayout.coordinateSpace)
                .onPreferenceChange(MealDropFramePreferenceKey.self) { frames in
                    mealDropFrames = frames
                }

                if let draggedEntryID,
                   let dragLocation,
                   let entry = selectedDayEntries.first(where: { $0.id == draggedEntryID }) {
                    GeometryReader { proxy in
                        FoodEntryDragPreview(entry: entry)
                            .position(
                                x: min(max(dragLocation.x, 140), proxy.size.width - 140),
                                y: max(dragLocation.y - 38, 30)
                            )
                    }
                    .allowsHitTesting(false)
                    .zIndex(20)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { dateNavigator }
                if isToday {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showCustomFoodCreate = true
                            } label: {
                                Label("Create Custom Food", systemImage: "square.and.pencil")
                            }

                            if !selectedDayEntries.isEmpty {
                                Button {
                                    beginSavingTemplate(entries: selectedDayEntries)
                                } label: {
                                    Label("Save Today as Template", systemImage: "square.and.arrow.down")
                                }
                            }

                            if !mealTemplates.isEmpty {
                                Divider()
                                ForEach(mealTemplates) { template in
                                    Button {
                                        templateToLog = template
                                        showTemplateMealPicker = true
                                    } label: {
                                        Label(template.name, systemImage: "rectangle.stack")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Food and meal template actions")
                    }
                }
            }
            .sheet(item: $selectedEntry) { entry in
                FoodEntryEditView(entry: entry)
            }
            .sheet(isPresented: $showCustomFoodCreate) {
                NavigationStack { CustomFoodCreateView() }
            }
            .sheet(isPresented: $showManualSearch) {
                ManualFoodSearchView(
                    isPresented: $showManualSearch,
                    initialMeal: selectedMealForSearch
                )
            }
            .sheet(isPresented: $showHydrationSheet) {
                HydrationSheetView(date: selectedDate)
            }
            .sheet(isPresented: $showNutritionDetail) {
                NutritionDetailView(
                    selectedDate: selectedDate,
                    entries: selectedDayEntries,
                    allEntries: allEntries,
                    goal: displayGoal,
                    activity: activityGoalSnapshot
                )
            }
            .alert("Delete this entry?", isPresented: $showDeleteFoodConfirm) {
                Button("Delete", role: .destructive) {
                    if let entry = deleteFoodEntry {
                        modelContext.delete(entry)
                        presentUndo("\(entry.name) removed")
                    }
                    deleteFoodEntry = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteFoodEntry = nil
                }
            } message: {
                if let entry = deleteFoodEntry {
                    Text("\(entry.name) — \(entry.calories.safeRoundedInt) cal")
                }
            }
            .alert("Couldn’t Move Food", isPresented: $showMoveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(moveErrorMessage)
            }
            .alert("Save Meal Template", isPresented: $showTemplateNamePrompt) {
                TextField("Template name", text: $newTemplateName)
                Button("Save") {
                    saveTemplate()
                }
                .disabled(newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    templateEntriesToSave = []
                }
            } message: {
                Text("Save these foods and portions for one-tap reuse.")
            }
            .confirmationDialog(
                "Add \(quickAddSource?.name ?? "food") to which meal?",
                isPresented: $showQuickAddMealPicker,
                titleVisibility: .visible
            ) {
                ForEach(MealCategory.allCases) { meal in
                    Button(meal.title) {
                        quickAdd(source: quickAddSource, to: meal)
                    }
                }
                Button("Cancel", role: .cancel) {
                    quickAddSource = nil
                }
            }
            .confirmationDialog(
                "Add \(templateToLog?.name ?? "template") to which meal?",
                isPresented: $showTemplateMealPicker,
                titleVisibility: .visible
            ) {
                ForEach(MealCategory.allCases) { meal in
                    Button(meal.title) {
                        logTemplate(templateToLog, to: meal)
                    }
                }
                Button("Cancel", role: .cancel) {
                    templateToLog = nil
                }
            }
            .onAppear { modelContext.undoManager = undoManager }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                if isToday { selectedDate = .now }
            }
            .onReceive(routeCenter.$currentRoute.compactMap { $0 }) { route in
                switch route {
                case .todayLog:
                    selectedDate = .now
                    routeCenter.clear(route)
                case .manualSearch:
                    selectedDate = .now
                    selectedMealForSearch = nil
                    showManualSearch = true
                    routeCenter.clear(route)
                case .hydration:
                    selectedDate = .now
                    showHydrationSheet = true
                    routeCenter.clear(route)
                default:
                    break
                }
            }
            .task {
                await garminManager.refreshIfNeeded()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let undoNotice {
                        HStack {
                            Text(undoNotice)
                                .font(.caption)
                            Spacer()
                            Button("Undo") {
                                undoManager?.undo()
                                try? modelContext.save()
                                self.undoNotice = nil
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, contentInset)
                    }
                    if isToday {
                        addFoodBar
                    }
                }
            }
        }
    }

    private var dateNavigator: some View {
        NomvaDateNavigator(
            label: dateLabel,
            isCurrent: isToday,
            canAdvance: !isToday,
            onPrevious: {
                selectedDate = cal.date(byAdding: .day, value: -1, to: selectedDate)!
            },
            onJumpToCurrent: {
                selectedDate = .now
            },
            onNext: {
                guard !isToday else { return }
                let next = cal.date(byAdding: .day, value: 1, to: selectedDate)!
                if next <= .now { selectedDate = next }
            }
        )
    }

    private var addFoodBar: some View {
        NomvaBottomActionBar {
            Button {
                selectedMealForSearch = nil
                showManualSearch = true
            } label: {
                Label("Add Food", systemImage: "plus")
            }
            .buttonStyle(NomvaPrimaryButtonStyle())
        }
    }

    private var navTitle: String { isToday ? "Today's Log" : "Log" }
    private var hydrationTopInset: CGFloat { selectedDayEntries.isEmpty ? 0 : NomvaTheme.sectionGap }

    private func foodEntryListRow(_ entry: FoodEntry, in meal: MealCategory) -> some View {
        FoodEntryRow(
            entry: entry,
            isMoving: draggedEntryID == entry.id,
            onMoveChanged: { location in
                updateFoodDrag(entry: entry, from: meal, location: location)
            },
            onMoveEnded: { location in
                finishFoodDrag(entry: entry, from: meal, location: location)
            }
        )
            .listRowInsets(EdgeInsets(top: 2, leading: contentInset, bottom: 2, trailing: contentInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .contentShape(Rectangle())
            .onTapGesture { selectedEntry = entry }
            .opacity(draggedEntryID == entry.id ? 0.3 : 1)
            .reportsDropFrame(for: meal)
            // Visible fallback for everyone who doesn't discover drag:
            // long-press offers the same move targets.
            .contextMenu {
                ForEach(MealCategory.allCases.filter { $0 != meal }) { destination in
                    Button {
                        _ = moveFoodEntries(with: [entry.id.uuidString], to: destination)
                    } label: {
                        Label("Move to \(destination.title)", systemImage: "arrow.turn.down.right")
                    }
                }
                Button {
                    toggleFavorite(entry)
                } label: {
                    Label(
                        entry.isFavorite ? "Remove Favorite" : "Add Favorite",
                        systemImage: entry.isFavorite ? "star.slash" : "star"
                    )
                }
            }
            .accessibilityHint("Double tap to edit. Use actions to move, favorite, or delete this food.")
            .accessibilityActions {
                ForEach(MealCategory.allCases.filter { $0 != meal }) { destination in
                    Button("Move to \(destination.title)") {
                        _ = moveFoodEntries(with: [entry.id.uuidString], to: destination)
                    }
                }
                Button(entry.isFavorite ? "Remove Favorite" : "Add Favorite") {
                    toggleFavorite(entry)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteFoodEntry = entry
                    showDeleteFoodConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    selectedEntry = entry
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(NomvaTheme.accent)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    toggleFavorite(entry)
                } label: {
                    Label(
                        entry.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: entry.isFavorite ? "star.slash" : "star"
                    )
                }
                .tint(NomvaTheme.warning)
            }
    }

    private func mealHeader(_ meal: MealCategory, entries: [FoodEntry]) -> some View {
        HStack {
            NomvaSectionHeaderText(title: meal.title)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(entries.reduce(0.0) { $0 + $1.calories }.safeRoundedInt) cal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)

            if isToday {
                Button {
                    selectedMealForSearch = meal.rawValue
                    showManualSearch = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(NomvaTheme.accent)
                        .font(.title3)
                }
                .padding(.leading, 8)
                .accessibilityLabel("Add food to \(meal.title)")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(targetedMeal == meal ? NomvaTheme.accent.opacity(0.15) : Color.clear)
                .padding(.horizontal, -8)
        }
        .contentShape(Rectangle())
        .nomvaSectionHeaderPadding()
        .reportsDropFrame(for: meal)
    }

    private func setDropTarget(_ meal: MealCategory?) {
        targetedMeal = meal
    }

    private func updateFoodDrag(
        entry: FoodEntry,
        from sourceMeal: MealCategory,
        location: CGPoint
    ) {
        draggedEntryID = entry.id
        dragLocation = location
        let destination = destinationMeal(at: location)
        setDropTarget(destination == sourceMeal ? nil : destination)
    }

    private func finishFoodDrag(
        entry: FoodEntry,
        from sourceMeal: MealCategory,
        location: CGPoint
    ) {
        let destination = destinationMeal(at: location) ?? targetedMeal
        draggedEntryID = nil
        dragLocation = nil
        targetedMeal = nil

        guard let destination, destination != sourceMeal else { return }
        _ = moveFoodEntries(with: [entry.id.uuidString], to: destination)
    }

    private func destinationMeal(at location: CGPoint) -> MealCategory? {
        mealDropFrames
            .filter { _, frame in
                frame.insetBy(dx: -8, dy: -6).contains(location)
            }
            .min { lhs, rhs in
                abs(lhs.value.midY - location.y) < abs(rhs.value.midY - location.y)
            }?
            .key
    }

    @discardableResult
    private func moveFoodEntries(with identifiers: [String], to meal: MealCategory) -> Bool {
        let ids = Set(identifiers.compactMap(UUID.init(uuidString:)))
        let entries = selectedDayEntries.filter {
            ids.contains($0.id) && $0.meal != meal.rawValue
        }
        guard !entries.isEmpty else {
            targetedMeal = nil
            return false
        }

        let originalMeals = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.meal) })

        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.22)) {
            entries.forEach { $0.meal = meal.rawValue }
            targetedMeal = nil
        }

        do {
            try modelContext.save()
            return true
        } catch {
            entries.forEach { entry in
                if let originalMeal = originalMeals[entry.id] {
                    entry.meal = originalMeal
                }
            }
            moveErrorMessage = "Your food stayed in its original meal. Please try again."
            showMoveError = true
            return false
        }
    }

    private func toggleFavorite(_ entry: FoodEntry) {
        let newValue = !entry.isFavorite
        let identity = favoriteIdentity(for: entry)
        for candidate in allEntries where favoriteIdentity(for: candidate) == identity {
            candidate.isFavorite = newValue
        }
        do {
            try modelContext.save()
        } catch {
            for candidate in allEntries where favoriteIdentity(for: candidate) == identity {
                candidate.isFavorite = !newValue
            }
            moveErrorMessage = "Nomva couldn't update that favorite. Please try again."
            showMoveError = true
        }
    }

    private func favoriteIdentity(for entry: FoodEntry) -> String {
        "\(entry.brand ?? "")|\(entry.name)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func quickAdd(source: FoodEntry?, to meal: MealCategory) {
        defer { quickAddSource = nil }
        guard let source else { return }
        let copy = copyEntry(source, meal: meal.rawValue, date: timestampForSelectedDay())
        commitInsertedEntries([copy], undoMessage: "\(source.name) added")
    }

    private func beginSavingTemplate(entries: [FoodEntry]) {
        guard !entries.isEmpty else { return }
        templateEntriesToSave = entries
        newTemplateName = isToday ? "Today's meals" : "\(dateLabel) meals"
        showTemplateNamePrompt = true
    }

    private func saveTemplate() {
        let name = newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !templateEntriesToSave.isEmpty else { return }

        let items = templateEntriesToSave.map { entry in
            MealTemplate.TemplateItem(
                foodName: entry.name,
                portionGrams: entry.portionGrams,
                calories: entry.calories,
                proteinG: entry.proteinG,
                carbsG: entry.carbsG,
                fatG: entry.fatG,
                brand: entry.brand,
                portionDescription: entry.portionDescription,
                servings: entry.servings,
                servingUnit: entry.servingUnit,
                fiberG: entry.fiberG,
                source: entry.source,
                fdcId: entry.fdcId,
                foodDatabaseId: entry.foodDatabaseId,
                barcode: entry.barcode
            )
        }

        if let existing = mealTemplates.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            existing.items = items
            existing.createdAt = .now
        } else {
            modelContext.insert(MealTemplate(name: name, items: items))
        }

        do {
            try modelContext.save()
        } catch {
            moveErrorMessage = "Nomva couldn't save that meal template. Please try again."
            showMoveError = true
        }
        templateEntriesToSave = []
        newTemplateName = ""
    }

    private func logTemplate(_ template: MealTemplate?, to meal: MealCategory) {
        defer { templateToLog = nil }
        guard let template, !template.items.isEmpty else { return }
        let start = timestampForSelectedDay()
        let entries = template.items.enumerated().map { index, item in
            let grams = max(item.portionGrams, 0)
            let per100Factor = grams > 0 ? 100 / grams : 0
            return FoodEntry(
                name: item.foodName,
                brand: item.brand,
                meal: meal.rawValue,
                date: start.addingTimeInterval(TimeInterval(index)),
                portionGrams: grams,
                portionDescription: item.portionDescription ?? "\(grams.safeRoundedInt) g",
                servings: item.servings ?? 1,
                servingUnit: item.servingUnit ?? "serving",
                calories: item.calories,
                proteinG: item.proteinG,
                carbsG: item.carbsG,
                fatG: item.fatG,
                fiberG: item.fiberG ?? 0,
                caloriesPer100g: item.calories * per100Factor,
                proteinPer100g: item.proteinG * per100Factor,
                carbsPer100g: item.carbsG * per100Factor,
                fatPer100g: item.fatG * per100Factor,
                fiberPer100g: (item.fiberG ?? 0) * per100Factor,
                rawUserInput: "Meal template: \(template.name)",
                fdcId: item.fdcId,
                foodDatabaseId: item.foodDatabaseId,
                source: item.source,
                barcode: item.barcode
            )
        }
        commitInsertedEntries(entries, undoMessage: "\(template.name) added")
    }

    private func commitInsertedEntries(_ entries: [FoodEntry], undoMessage: String) {
        guard !entries.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        entries.forEach(modelContext.insert)
        undoManager?.endUndoGrouping()

        do {
            try modelContext.save()
            presentUndo(undoMessage)
        } catch {
            entries.forEach(modelContext.delete)
            moveErrorMessage = "Nomva couldn't save those foods. Nothing was added."
            showMoveError = true
        }
    }

    private func copyEntry(_ source: FoodEntry, meal: String, date: Date) -> FoodEntry {
        FoodEntry(
            name: source.name,
            brand: source.brand,
            meal: meal,
            date: date,
            portionGrams: source.portionGrams,
            portionDescription: source.portionDescription,
            servings: source.servings,
            servingUnit: source.servingUnit,
            calories: source.calories,
            proteinG: source.proteinG,
            carbsG: source.carbsG,
            fatG: source.fatG,
            fiberG: source.fiberG,
            sugarG: source.sugarG,
            sodiumMg: source.sodiumMg,
            saturatedFatG: source.saturatedFatG,
            transFatG: source.transFatG,
            cholesterolMg: source.cholesterolMg,
            addedSugarG: source.addedSugarG,
            vitaminDMcg: source.vitaminDMcg,
            calciumMg: source.calciumMg,
            ironMg: source.ironMg,
            potassiumMg: source.potassiumMg,
            vitaminAMcgRAE: source.vitaminAMcgRAE,
            vitaminCMg: source.vitaminCMg,
            vitaminB12Mcg: source.vitaminB12Mcg,
            folateMcgDFE: source.folateMcgDFE,
            magnesiumMg: source.magnesiumMg,
            zincMg: source.zincMg,
            caloriesPer100g: source.caloriesPer100g,
            proteinPer100g: source.proteinPer100g,
            carbsPer100g: source.carbsPer100g,
            fatPer100g: source.fatPer100g,
            fiberPer100g: source.fiberPer100g,
            sugarPer100g: source.sugarPer100g,
            sodiumPer100g: source.sodiumPer100g,
            saturatedFatPer100g: source.saturatedFatPer100g,
            transFatPer100g: source.transFatPer100g,
            cholesterolPer100g: source.cholesterolPer100g,
            addedSugarPer100g: source.addedSugarPer100g,
            vitaminDPer100g: source.vitaminDPer100g,
            calciumPer100g: source.calciumPer100g,
            ironPer100g: source.ironPer100g,
            potassiumPer100g: source.potassiumPer100g,
            vitaminAPer100g: source.vitaminAPer100g,
            vitaminCPer100g: source.vitaminCPer100g,
            vitaminB12Per100g: source.vitaminB12Per100g,
            folatePer100g: source.folatePer100g,
            magnesiumPer100g: source.magnesiumPer100g,
            zincPer100g: source.zincPer100g,
            rawUserInput: "Quick add",
            fdcId: source.fdcId,
            foodDatabaseId: source.foodDatabaseId,
            source: source.source,
            barcode: source.barcode
        )
    }

    private func timestampForSelectedDay() -> Date {
        if isToday { return .now }
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: selectedDate) ?? selectedDate
    }

    private func presentUndo(_ message: String) {
        undoNotice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if undoNotice == message {
                undoNotice = nil
            }
        }
    }

    private var dateLabel: String {
        if isToday { return "Today" }
        if cal.isDateInYesterday(selectedDate) { return "Yesterday" }
        let df = DateFormatter()
        df.dateFormat = cal.component(.year, from: selectedDate) == cal.component(.year, from: .now)
            ? "MMM d" : "MMM d, yyyy"
        return df.string(from: selectedDate)
    }

    private var emptyLogView: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.system(size: 34))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No food logged yet")
                .font(.headline)
            if isToday {
                Text("Tap Add Food to log your first meal.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
    }

    private var garminActivityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Garmin Activity")
                        .font(.headline)
                    Text(garminDateCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if garminManager.isSyncing {
                    ProgressView()
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "figure.walk.motion")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(NomvaTheme.accent)
                        .frame(width: 40, height: 40)
                        .background(NomvaTheme.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            if garminManager.isSyncing && garminSummaryForSelectedDate == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing with Garmin…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if let summary = garminSummaryForSelectedDate {
                HStack(spacing: 12) {
                    GarminLogStat(
                        title: "Active Calories",
                        value: "\(summary.activeCalories.safeRoundedInt)",
                        detail: isToday ? "so far" : "kcal"
                    )
                    GarminLogStat(
                        title: "Steps",
                        value: summary.steps.map { $0.formatted() } ?? "—",
                        detail: "steps"
                    )
                }

                if selectedActivitySource == .garmin {
                    Text(goalAdjustmentCaption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Garmin is connected, but your goal is still using \(selectedActivitySource.displayName.lowercased()). Change it in Settings > Goals if you want daily adjustments.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if isToday {
                // Today but no Garmin data yet — still show goal info from average
                if selectedActivitySource == .garmin, let avg = garminManager.averageActiveCalories, avg > 0 {
                    Text(goalAdjustmentCaption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("No Garmin activity synced for today yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await garminManager.manualSync() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.trianglehead.2.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NomvaTheme.accent)
                    }
                }
            } else {
                Text("No Garmin data for this date.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                routeCenter.handle(url: NomvaWidgetRoute.goals.url)
            } label: {
                Label("Review Calorie Goal", systemImage: "target")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NomvaTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .nomvaCard(.standard, padding: NomvaTheme.standardCardPadding)
    }

    private var garminDateCaption: String {
        if isToday {
            return "Today's synced activity"
        }
        return "Synced activity for \(dateLabel)"
    }

    /// Explains how the rolling baseline and the selected day's activity affect the goal.
    private var goalAdjustmentCaption: String {
        let base = currentGoal.calories

        if !isToday, let summary = garminSummaryForSelectedDate {
            // Past date with completed data — show actual delta
            let delta = GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: base,
                dailyActiveCalories: summary.activeCalories,
                referenceActiveCalories: activityReferenceActiveCalories
            ) - base
            let rounded = delta.safeRoundedInt
            if rounded == 0 {
                return "Your calorie goal matched your Garmin baseline for this day."
            } else if rounded > 0 {
                return "Garmin activity added \(rounded) kcal to your base goal."
            } else {
                return "Garmin activity trimmed \(abs(rounded)) kcal from your base goal."
            }
        }

        // A partial current day can earn calories above baseline, but cannot reduce the goal.
        if let avg = garminManager.averageActiveCalories, avg > 0 {
            let baselineDelta = GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: base,
                dailyActiveCalories: avg,
                referenceActiveCalories: activityReferenceActiveCalories
            ) - base
            let avgRounded = avg.safeRoundedInt
            let baselineNote: String
            let roundedBaselineDelta = baselineDelta.safeRoundedInt
            if roundedBaselineDelta > 0 {
                baselineNote = " This baseline is \(roundedBaselineDelta) kcal above the one saved with your goal."
            } else if roundedBaselineDelta < 0 {
                baselineNote = " This baseline is \(abs(roundedBaselineDelta)) kcal below the one saved with your goal."
            } else {
                baselineNote = ""
            }

            if isToday, let summary = garminSummaryForSelectedDate {
                let activeRounded = summary.activeCalories.safeRoundedInt
                let earned = max(summary.activeCalories - avg, 0).safeRoundedInt
                if earned > 0 {
                    return "Garmin estimates \(activeRounded) active kcal today, \(earned) above your \(avgRounded)-kcal recent baseline. That adds \(earned) kcal to today's target.\(baselineNote)"
                }
                return "Today's target includes your \(avgRounded)-kcal recent activity baseline. Garmin estimates \(activeRounded) active kcal so far; activity above the baseline will add the same number of calories to today's target.\(baselineNote)"
            }

            return "Today's target includes your \(avgRounded)-kcal recent Garmin activity baseline. Synced active calories above it add the same number of calories to today's target.\(baselineNote)"
        }

        return "Your calorie goal will adjust after Garmin has enough completed-day activity data."
    }

}

struct FoodEntryRow: View {
    let entry: FoodEntry
    let isMoving: Bool
    let onMoveChanged: (CGPoint) -> Void
    let onMoveEnded: (CGPoint) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline).bold().lineLimit(1)
                    .foregroundColor(.primary)
                if let brand = entry.brand { 
                    Text(brand).font(.caption).foregroundColor(.secondary) 
                }
                Text(entry.portionDescription).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(entry.calories.safeRoundedInt) cal").font(.subheadline).bold()
                    .foregroundColor(.primary)
                Text("\(entry.proteinG.safeRoundedInt)g P · \(entry.carbsG.safeRoundedInt)g C · \(entry.fatG.safeRoundedInt)g F").font(.caption2).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isMoving ? NomvaTheme.accent : .secondary.opacity(0.7))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
                    .highPriorityGesture(moveGesture)
                    .accessibilityHidden(true)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.brand.map { "\(entry.name), \($0)" } ?? entry.name)
        .accessibilityValue(
            "\(entry.portionDescription), \(entry.calories.safeRoundedInt) calories, "
            + "\(entry.proteinG.safeRoundedInt) grams protein, "
            + "\(entry.carbsG.safeRoundedInt) grams carbs, "
            + "\(entry.fatG.safeRoundedInt) grams fat"
        )
        .accessibilityHint("Double tap to edit. Additional actions can move or delete this food.")
    }

    private var moveGesture: some Gesture {
        DragGesture(
            minimumDistance: 2,
            coordinateSpace: .named(MealDropLayout.coordinateSpace)
        )
        .onChanged { value in
            onMoveChanged(value.location)
        }
        .onEnded { value in
            onMoveEnded(value.location)
        }
    }
}

private struct EmptyMealDropZone: View {
    let isTargeted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray")
                .foregroundStyle(isTargeted ? NomvaTheme.accent : Color.secondary)
            Text("No entries")
                .font(.subheadline)
                .foregroundStyle(isTargeted ? NomvaTheme.accent : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? NomvaTheme.accent.opacity(0.14) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isTargeted ? NomvaTheme.accent : NomvaTheme.line,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.16), value: isTargeted)
        .accessibilityLabel("Empty meal")
    }
}

private struct FoodEntryDragPreview: View {
    let entry: FoodEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "fork.knife")
                .foregroundStyle(NomvaTheme.accent)
            Text(entry.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(entry.calories.safeRoundedInt) cal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 260)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(NomvaTheme.line, lineWidth: 1)
        }
    }
}

private struct GarminLogStat: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(NomvaTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NomvaTheme.chipHorizontalPadding)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    DailyLogView()
        .environmentObject(GarminManager.shared)
        .environmentObject(NomvaRouteCenter.shared)
}
