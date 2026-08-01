import SwiftUI
import SwiftData

struct ManualFoodSearchView: View {
    @Query(sort: \CustomFood.createdAt, order: .reverse) private var customFoods: [CustomFood]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText: String
    @State private var results: [FoodItem] = []
    @State private var isSearching = false
    @State private var showScanner = false
    @State private var selectedFood: FoodItem? = nil
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
            ZStack {
                if results.isEmpty && searchText.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundStyle(.orange.opacity(0.3))
                        Text("Search for foods or scan a barcode")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                
                List {
                    if results.isEmpty && !searchText.isEmpty && !isSearching {
                        // No dead ends: the recovery action is right where
                        // the user is looking.
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No results found for \"\(searchText)\"")
                                .foregroundStyle(.secondary)
                            Button {
                                showCustomFoodCreate = true
                            } label: {
                                Label("Create \"\(searchText)\" as a Custom Food", systemImage: "square.and.pencil")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    ForEach(results) { food in
                        Button {
                            selectedFood = food
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
                                // "214 cal" of what? Always anchor the number
                                // to its serving.
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(food.caloriesPerServing.safeRoundedInt) cal")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.orange)
                                    Text("per serving")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
                .listStyle(.plain)
            }
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
            .sheet(item: $selectedFood) { food in
                ManualFoodDetailView(food: food, meal: initialMeal) {
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
    
    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        isSearching = true
        Task {
            let digits = trimmed.filter(\.isNumber)
            let found: [FoodItem]

            if digits.count >= 8, digits.count == trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").count {
                if let custom = customFood(matchingBarcode: trimmed) {
                    found = [foodItem(from: custom)]
                } else {
                    let outcome = await BarcodeLookupService.shared.lookup(barcode: trimmed)
                    switch outcome {
                    case let .found(food, _):
                        found = [food]
                    case .notFound, .unavailable:
                        found = []
                    }
                }
            } else {
                found = await FoodLoggingService.shared.searchFoodsForManualEntry(
                    query: trimmed,
                    customFoods: customFoods,
                    limit: 30
                )
            }

            await MainActor.run {
                self.results = found
                self.isSearching = false
            }
        }
    }

    private func handleScannedBarcode(_ barcode: String) {
        showScanner = false
        pendingBarcode = barcode

        if let custom = customFood(matchingBarcode: barcode) {
            selectedFood = foodItem(from: custom)
            return
        }

        Task {
            let outcome = await BarcodeLookupService.shared.lookup(barcode: barcode)
            await MainActor.run {
                switch outcome {
                case let .found(match, _):
                    selectedFood = match
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
