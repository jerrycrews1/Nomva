import SwiftUI
import SwiftData

struct ManualFoodSearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    @State private var results: [FoodItem] = []
    @State private var isSearching = false
    @State private var showScanner = false
    @State private var selectedFood: FoodItem? = nil
    @State private var scannerAlertText = ""
    @State private var showScannerAlert = false
    
    // To dismiss both this search sheet and the child detail sheet
    @Binding var isPresented: Bool
    
    let db = DatabaseManager.shared
    
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
                        Text("No results found for \"\(searchText)\"")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    
                    ForEach(results) { food in
                        Button {
                            selectedFood = food
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(food.name)
                                        .font(.headline)
                                    if let brand = food.brand {
                                        Text(brand)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(Int(food.caloriesPerServing)) cal")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.orange)
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
                performSearch()
            }
            .onAppear {
                // @FocusState can't target .searchable's UISearchBar, so
                // we find and activate it directly after the sheet animates in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    focusSearchBar()
                }
            }
            .sheet(item: $selectedFood) { food in
                ManualFoodDetailView(food: food) {
                    // This is called when food is logged
                    isPresented = false
                }
            }
            .alert("Barcode Not Found", isPresented: $showScannerAlert) {
                Button("OK", role: .cancel) {}
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
                let outcome = await BarcodeLookupService.shared.lookup(barcode: trimmed)
                switch outcome {
                case let .found(food, _):
                    found = [food]
                case .notFound, .unavailable:
                    found = []
                }
            } else {
                found = await db.search(query: trimmed, limit: 30)
            }

            await MainActor.run {
                self.results = found
                self.isSearching = false
            }
        }
    }

    private func handleScannedBarcode(_ barcode: String) {
        showScanner = false

        Task {
            let outcome = await BarcodeLookupService.shared.lookup(barcode: barcode)
            await MainActor.run {
                switch outcome {
                case let .found(match, _):
                    selectedFood = match
                case .notFound:
                    scannerAlertText = "No food matched barcode \(barcode) in Nomva or Open Food Facts. Try typing the food name instead."
                    showScannerAlert = true
                case .unavailable:
                    scannerAlertText = "Couldn’t look up barcode \(barcode) right now. Check your connection or type the food name instead."
                    showScannerAlert = true
                }
            }
        }
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
            caloriesPer100g: food.per100g.calories,
            proteinPer100g: food.per100g.protein,
            carbsPer100g: food.per100g.carbs,
            fatPer100g: food.per100g.fat,
            fiberPer100g: food.per100g.fiber,
            rawUserInput: "Manual entry",
            fdcId: food.fdcId
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
