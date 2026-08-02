import SwiftUI
import SwiftData
import UIKit

private enum ManualFoodSearchScope: String, CaseIterable, Identifiable {
    case all = "All Foods"
    case history = "History"

    var id: Self { self }
}

private struct ManualFoodSelection: Identifiable {
    let id = UUID()
    let food: FoodItem
    let initialQuantity: Double
}

struct ManualFoodSearchView: View {
    @Query(sort: \CustomFood.createdAt, order: .reverse) private var customFoods: [CustomFood]
    @Query(sort: \FoodEntry.date, order: .reverse) private var foodHistory: [FoodEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText: String
    @State private var results: [FoodItem] = []
    @State private var isSearching = false
    @State private var searchScope: ManualFoodSearchScope = .all
    @State private var showScanner = false
    @State private var selectedFood: ManualFoodSelection? = nil
    @State private var scannerAlertText = ""
    @State private var showScannerAlert = false
    @State private var pendingBarcode = ""
    @State private var showCustomFoodCreate = false
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    
    // To dismiss both this search sheet and the child detail sheet
    @Binding var isPresented: Bool
    private let initialMeal: String?
    
    let db = DatabaseManager.shared

    init(
        isPresented: Binding<Bool>,
        initialQuery: String = "",
        initialMeal: String? = nil
    ) {
        _isPresented = isPresented
        _searchText = State(initialValue: initialQuery)
        self.initialMeal = initialMeal
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Search Source", selection: $searchScope) {
                        ForEach(ManualFoodSearchScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if trimmedSearchText.isEmpty && matchingHistory.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundStyle(NomvaTheme.accent.opacity(0.45))
                        Text(searchScope == .history
                             ? "Your previously logged foods will appear here"
                             : "Search for foods or scan a barcode")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 56)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if !matchingHistory.isEmpty {
                    Section("Previously Logged") {
                        ForEach(matchingHistory) { entry in
                            historyResultRow(entry)
                        }
                    }
                }

                if searchScope == .all, isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching all foods...")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if searchScope == .all, !results.isEmpty {
                    Section("Food Database") {
                        ForEach(results) { food in
                            databaseResultRow(food)
                        }
                    }
                }

                if !trimmedSearchText.isEmpty && !hasVisibleResults && !isSearching {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No results found for \"\(trimmedSearchText)\"")
                            .foregroundStyle(.secondary)

                        if searchScope == .history {
                            Button {
                                searchScope = .all
                            } label: {
                                Label("Search All Foods", systemImage: "magnifyingglass")
                                    .font(.subheadline.weight(.semibold))
                            }
                        } else {
                            Button {
                                showCustomFoodCreate = true
                            } label: {
                                Label("Create \"\(trimmedSearchText)\" as a Custom Food", systemImage: "square.and.pencil")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods...")
            .onChange(of: searchText) { oldValue, newValue in
                // Debounce: two synchronous SQLite queries per keystroke
                // causes typing jank and result flicker on older devices.
                searchDebounceTask?.cancel()
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    performSearch()
                }
            }
            .onChange(of: searchScope) { _, newScope in
                searchDebounceTask?.cancel()
                if newScope == .all {
                    performSearch()
                } else {
                    results = []
                    isSearching = false
                }
            }
            .onAppear {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    performSearch()
                }
                // @FocusState can't target .searchable's UISearchBar, so
                // we find and activate it directly after the sheet animates in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    focusSearchBar()
                }
            }
            .sheet(item: $selectedFood) { selection in
                ManualFoodDetailView(
                    food: selection.food,
                    meal: initialMeal,
                    initialQuantity: selection.initialQuantity
                ) {
                    // This is called when food is logged
                    isPresented = false
                }
            }
            .alert("Barcode Not Found", isPresented: $showScannerAlert) {
                Button("Create Custom Food") {
                    showCustomFoodCreate = true
                }
                Button("Search by Name") {
                    searchText = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(scannerAlertText)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView { barcode in
                    handleScannedBarcode(barcode)
                }
            }
            .sheet(isPresented: $showCustomFoodCreate) {
                NavigationStack {
                    CustomFoodCreateView(
                        initialBarcode: pendingBarcode,
                        initialName: pendingBarcode.isEmpty ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    )
                }
            }
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var distinctHistory: [FoodEntry] {
        var seen = Set<String>()

        return foodHistory.filter { entry in
            let key = "\(normalizedSearchText(entry.name))|\(normalizedSearchText(entry.brand ?? ""))"
            guard key != "|" else { return false }
            return seen.insert(key).inserted
        }
    }

    private var matchingHistory: [FoodEntry] {
        let entries = distinctHistory
        let queryTokens = normalizedSearchText(trimmedSearchText)
            .split(separator: " ")
            .map(String.init)

        guard !queryTokens.isEmpty else {
            return Array(entries.prefix(20))
        }

        return Array(entries.lazy.filter { entry in
            let searchable = normalizedSearchText("\(entry.name) \(entry.brand ?? "")")
            return queryTokens.allSatisfy(searchable.contains)
        }.prefix(40))
    }

    private var hasVisibleResults: Bool {
        !matchingHistory.isEmpty || (searchScope == .all && !results.isEmpty)
    }

    private func historyResultRow(_ entry: FoodEntry) -> some View {
        Button {
            selectedFood = selection(from: entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(NomvaTheme.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if let brand = entry.brand, !brand.isEmpty {
                            Text(brand)
                        }
                        if !entry.portionDescription.isEmpty {
                            if let brand = entry.brand, !brand.isEmpty { Text("·") }
                            Text(entry.portionDescription)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(entry.calories.safeRoundedInt) cal")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(NomvaTheme.accent)
                    Text("last logged")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.name
            } label: {
                Label("Copy Food Name", systemImage: "doc.on.doc")
            }
        }
    }

    private func databaseResultRow(_ food: FoodItem) -> some View {
        Button {
            selectedFood = ManualFoodSelection(food: food, initialQuantity: 1)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(food.name)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if let brand = food.brand {
                            Text(brand)
                        }
                        if let serving = food.servingDesc, !serving.isEmpty {
                            if food.brand != nil { Text("·") }
                            Text(serving)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(food.caloriesPerServing.safeRoundedInt) cal")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(NomvaTheme.accent)
                    Text("per serving")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func selection(from entry: FoodEntry) -> ManualFoodSelection {
        let servingCount = entry.servings.isFinite && entry.servings > 0 ? entry.servings : 1
        let gramsPerServing = entry.portionGrams.isFinite && entry.portionGrams > 0
            ? entry.portionGrams / servingCount
            : 100
        let divisor = max(servingCount, 0.01)

        let food = FoodItem(
            id: entry.foodDatabaseId ?? historyFoodID(for: entry.id),
            fdcId: entry.fdcId,
            name: entry.name,
            brand: entry.brand,
            source: entry.source ?? "history",
            servingGrams: gramsPerServing,
            servingDesc: historyServingDescription(from: entry.servingUnit),
            caloriesPerServing: entry.calories / divisor,
            proteinG: entry.proteinG / divisor,
            carbsG: entry.carbsG / divisor,
            fatG: entry.fatG / divisor,
            fiberG: entry.fiberG / divisor,
            sugarG: entry.sugarG / divisor,
            sodiumMg: entry.sodiumMg / divisor,
            saturatedFatG: entry.saturatedFatG.map { $0 / divisor },
            transFatG: entry.transFatG.map { $0 / divisor },
            cholesterolMg: entry.cholesterolMg.map { $0 / divisor },
            addedSugarG: entry.addedSugarG.map { $0 / divisor },
            vitaminDMcg: entry.vitaminDMcg.map { $0 / divisor },
            calciumMg: entry.calciumMg.map { $0 / divisor },
            ironMg: entry.ironMg.map { $0 / divisor },
            potassiumMg: entry.potassiumMg.map { $0 / divisor },
            vitaminAMcgRAE: entry.vitaminAMcgRAE.map { $0 / divisor },
            vitaminCMg: entry.vitaminCMg.map { $0 / divisor },
            vitaminB12Mcg: entry.vitaminB12Mcg.map { $0 / divisor },
            folateMcgDFE: entry.folateMcgDFE.map { $0 / divisor },
            magnesiumMg: entry.magnesiumMg.map { $0 / divisor },
            zincMg: entry.zincMg.map { $0 / divisor },
            barcode: entry.barcode,
            portionBasis: .grams,
            servingSource: .explicitServing
        )

        return ManualFoodSelection(food: food, initialQuantity: servingCount)
    }

    private func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func historyFoodID(for id: UUID) -> Int {
        id.uuidString.unicodeScalars.reduce(2_000_000) {
            (($0 &* 31) &+ Int($1.value)) & Int.max
        }
    }

    private func historyServingDescription(from rawValue: String) -> String {
        var words = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        if let first = words.first,
           Double(first.replacingOccurrences(of: ",", with: "")) != nil {
            words.removeFirst()
        }

        let unit = words.joined(separator: " ").lowercased()
        guard !unit.isEmpty else { return "serving" }

        if unit.hasSuffix("ies"), unit.count > 3 {
            return String(unit.dropLast(3)) + "y"
        }
        if ["ches", "shes", "xes", "zes"].contains(where: unit.hasSuffix) {
            return String(unit.dropLast(2))
        }
        if unit.hasSuffix("s"), unit.count > 1, !unit.hasSuffix("ss") {
            return String(unit.dropLast())
        }
        return unit
    }
    
    private func performSearch() {
        let requestedQuery = trimmedSearchText
        guard searchScope == .all, !requestedQuery.isEmpty else {
            results = []
            isSearching = false
            return
        }

        results = []
        isSearching = true
        Task {
            let digits = requestedQuery.filter(\.isNumber)
            let found: [FoodItem]

            if digits.count >= 8, digits.count == requestedQuery.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").count {
                if let custom = customFood(matchingBarcode: requestedQuery) {
                    found = [foodItem(from: custom)]
                } else {
                    let outcome = await BarcodeLookupService.shared.lookup(barcode: requestedQuery)
                    switch outcome {
                    case let .found(food, _):
                        found = [food]
                    case .notFound, .unavailable:
                        found = []
                    }
                }
            } else {
                found = await FoodLoggingService.shared.searchFoodsForManualEntry(
                    query: requestedQuery,
                    customFoods: customFoods,
                    limit: 30
                )
            }

            await MainActor.run {
                guard searchScope == .all, trimmedSearchText == requestedQuery else { return }
                self.results = found
                self.isSearching = false
            }
        }
    }

    private func handleScannedBarcode(_ barcode: String) {
        showScanner = false
        pendingBarcode = barcode

        if let custom = customFood(matchingBarcode: barcode) {
            selectedFood = ManualFoodSelection(food: foodItem(from: custom), initialQuantity: 1)
            return
        }

        Task {
            let outcome = await BarcodeLookupService.shared.lookup(barcode: barcode)
            await MainActor.run {
                switch outcome {
                case let .found(match, _):
                    selectedFood = ManualFoodSelection(food: match, initialQuantity: 1)
                case .notFound:
                    scannerAlertText = "No food matched barcode \(barcode). Create it once and Nomva will recognize this code next time."
                    showScannerAlert = true
                case .unavailable:
                    scannerAlertText = "Barcode lookup is unavailable. You can create this food with barcode \(barcode) already filled in."
                    showScannerAlert = true
                }
            }
        }
    }

    private func customFood(matchingBarcode barcode: String) -> CustomFood? {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return customFoods.first { $0.barcode?.filter(\.isNumber) == digits }
    }

    private func foodItem(from food: CustomFood) -> FoodItem {
        FoodItem(
            id: food.id.uuidString.unicodeScalars.reduce(1_000_000) {
                (($0 &* 31) &+ Int($1.value)) & Int.max
            },
            name: food.name,
            brand: food.brand,
            source: "custom",
            servingGrams: food.servingGrams,
            servingDesc: food.servingDesc,
            caloriesPerServing: food.calories,
            proteinG: food.proteinG,
            carbsG: food.carbsG,
            fatG: food.fatG,
            fiberG: food.fiberG,
            sugarG: 0,
            sodiumMg: 0,
            barcode: food.barcode
        )
    }
    
    private func logFood(_ food: FoodItem) {
        let entry = FoodEntry(
            name: food.name,
            brand: food.brand,
            meal: currentMealTime(),
            portionGrams: food.servingGrams ?? 100,
            portionDescription: food.servingDesc ?? "1 serving",
            calories: food.caloriesPerServing,
            proteinG: food.proteinG,
            carbsG: food.carbsG,
            fatG: food.fatG,
            fiberG: food.fiberG,
            sugarG: food.sugarG,
            sodiumMg: food.sodiumMg,
            saturatedFatG: food.saturatedFatG,
            transFatG: food.transFatG,
            cholesterolMg: food.cholesterolMg,
            addedSugarG: food.addedSugarG,
            vitaminDMcg: food.vitaminDMcg,
            calciumMg: food.calciumMg,
            ironMg: food.ironMg,
            potassiumMg: food.potassiumMg,
            vitaminAMcgRAE: food.vitaminAMcgRAE,
            vitaminCMg: food.vitaminCMg,
            vitaminB12Mcg: food.vitaminB12Mcg,
            folateMcgDFE: food.folateMcgDFE,
            magnesiumMg: food.magnesiumMg,
            zincMg: food.zincMg,
            caloriesPer100g: food.per100g.calories,
            proteinPer100g: food.per100g.protein,
            carbsPer100g: food.per100g.carbs,
            fatPer100g: food.per100g.fat,
            fiberPer100g: food.per100g.fiber,
            sugarPer100g: food.per100g.sugar,
            sodiumPer100g: food.per100g.sodium,
            saturatedFatPer100g: food.per100g.saturatedFat,
            transFatPer100g: food.per100g.transFat,
            cholesterolPer100g: food.per100g.cholesterol,
            addedSugarPer100g: food.per100g.addedSugar,
            vitaminDPer100g: food.per100g.vitaminD,
            calciumPer100g: food.per100g.calcium,
            ironPer100g: food.per100g.iron,
            potassiumPer100g: food.per100g.potassium,
            vitaminAPer100g: food.per100g.vitaminA,
            vitaminCPer100g: food.per100g.vitaminC,
            vitaminB12Per100g: food.per100g.vitaminB12,
            folatePer100g: food.per100g.folate,
            magnesiumPer100g: food.per100g.magnesium,
            zincPer100g: food.per100g.zinc,
            rawUserInput: "Manual entry",
            fdcId: food.fdcId,
            foodDatabaseId: food.id,
            source: food.source,
            barcode: food.barcode
        )
        modelContext.insert(entry)
        dismiss()
    }
    
    private func currentMealTime() -> String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 11 { return "breakfast" }
        if hour < 15 { return "lunch" }
        if hour < 20 { return "dinner" }
        return "snack"
    }

    /// Walk the key window's view hierarchy to find the UISearchBar
    /// and make it first responder so the keyboard opens automatically.
    private func focusSearchBar() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: \.isKeyWindow)
        else { return }

        func findSearchBar(in view: UIView) -> UISearchBar? {
            if let sb = view as? UISearchBar { return sb }
            for sub in view.subviews {
                if let found = findSearchBar(in: sub) { return found }
            }
            return nil
        }

        if let searchBar = findSearchBar(in: window) {
            searchBar.becomeFirstResponder()
        }
    }
}
