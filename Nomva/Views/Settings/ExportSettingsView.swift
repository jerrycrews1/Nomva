import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExportSettingsView: View {
    @Query private var foods: [FoodEntry]
    @Query private var weights: [WeightEntry]
    @Query private var goals: [DailyGoal]
    @Query private var water: [WaterEntry]
    @Environment(\.modelContext) private var modelContext
    
    @State private var selectedRange: ExportRange = .last30Days
    @State private var reportDetail: ExportService.DetailLevel = .detailed
    @State private var includeFood = true
    @State private var includeWeight = true
    @State private var includeWater = true
    
    @State private var showFileImporter = false
    @State private var importError: String?
    
    enum ExportRange: String, CaseIterable {
        case last7Days = "Last 7 Days"
        case last30Days = "Last 30 Days"
        case thisMonth = "This Month"
        case fullHistory = "Full History"
    }
    
    private var filteredData: (foods: [FoodEntry], weights: [WeightEntry], water: [WaterEntry]) {
        let cal = Calendar.current
        let now = Date.now
        let startDate: Date?
        
        switch selectedRange {
        case .last7Days: startDate = cal.date(byAdding: .day, value: -7, to: now)
        case .last30Days: startDate = cal.date(byAdding: .day, value: -30, to: now)
        case .thisMonth: startDate = cal.date(from: cal.dateComponents([.year, .month], from: now))
        case .fullHistory: startDate = nil
        }
        
        let f = foods.filter { includeFood && (startDate == nil || $0.date >= startDate!) }
        let w = weights.filter { includeWeight && (startDate == nil || $0.date >= startDate!) }
        let h = water.filter { includeWater && (startDate == nil || $0.date >= startDate!) }
        
        return (f, w, h)
    }

    var body: some View {
        ZStack {
            NomvaScreenBackground()
            
            ScrollView {
                VStack(spacing: 24) {
                    
                    SettingsSectionCard("Export Settings", detail: "Choose exactly what you want to share.") {
                        VStack(spacing: 16) {
                            Picker("Date Range", selection: $selectedRange) {
                                ForEach(ExportRange.allCases, id: \.self) { range in
                                    Text(range.rawValue).tag(range)
                                }
                            }
                            .pickerStyle(.segmented)
                            
                            Divider()
                            
                            VStack(spacing: 12) {
                                Toggle("Food Logs", isOn: $includeFood)
                                Toggle("Weight History", isOn: $includeWeight)
                                Toggle("Hydration", isOn: $includeWater)
                            }
                            .tint(.orange)
                        }
                    }
                    
                    SettingsSectionCard("Fitness Coach Report", detail: "Generate a human-readable CSV file containing your meals, macros, and weight history. Perfect for sharing with a coach or nutritionist.") {
                        VStack(spacing: 16) {
                            Picker("Report Style", selection: $reportDetail) {
                                Text("Macros Only").tag(ExportService.DetailLevel.summary)
                                Text("All Details").tag(ExportService.DetailLevel.detailed)
                            }
                            .pickerStyle(.segmented)
                            
                            Button {
                                let data = filteredData
                                if let url = ExportService.shared.generateCoachReport(entries: data.foods, weights: data.weights, detailLevel: reportDetail) {
                                    shareFile(url: url)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                    Text("Generate CSV Report")
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .padding()
                                .background(Color.orange.opacity(0.1))
                                .foregroundColor(.orange)
                                .cornerRadius(12)
                            }
                        }
                    }
                    
                    SettingsSectionCard("Full App Backup", detail: "Complete JSON backup of all your Nomva data.") {
                        VStack(spacing: 12) {
                            Button {
                                let data = filteredData
                                if let url = ExportService.shared.generateBackup(foods: data.foods, weights: data.weights, goals: goals, water: data.water) {
                                    shareFile(url: url)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "archivebox.fill")
                                    Text("Export JSON Backup")
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .padding()
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(12)
                            }
                            
                            Button {
                                showFileImporter = true
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.down.fill")
                                    Text("Restore from Backup")
                                    Spacer()
                                }
                                .padding()
                                .background(Color.green.opacity(0.1))
                                .foregroundColor(.green)
                                .cornerRadius(12)
                            }
                        }
                    }
                    
                    if let error = importError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Backup & Export")
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }
    
    private func shareFile(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Security: Request access to the file
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let data = try Data(contentsOf: url)
                let backup = try JSONDecoder().decode(ExportService.BackupData.self, from: data)
                
                // 1. Fetch current data for comparison
                let existingFoods = try modelContext.fetch(FetchDescriptor<FoodEntry>())
                let existingWeights = try modelContext.fetch(FetchDescriptor<WeightEntry>())
                let existingWater = try modelContext.fetch(FetchDescriptor<WaterEntry>())
                
                var addedCount = 0
                
                // 2. Smart Merge Food
                for f in backup.foods {
                    let isDuplicate = existingFoods.contains { 
                        $0.name == f.name && $0.meal == f.meal && abs($0.date.timeIntervalSince(f.date)) < 1
                    }
                    if !isDuplicate {
                        modelContext.insert(restoreFood(f))
                        addedCount += 1
                    }
                }
                
                // 3. Smart Merge Weight
                for w in backup.weights {
                    let isDuplicate = existingWeights.contains {
                        abs($0.date.timeIntervalSince(w.date)) < 1 && $0.weightLbs == w.lbs
                    }
                    if !isDuplicate {
                        modelContext.insert(WeightEntry(date: w.date, weightLbs: w.lbs, note: w.note))
                        addedCount += 1
                    }
                }
                
                // 4. Smart Merge Water
                for h in backup.water {
                    let isDuplicate = existingWater.contains {
                        abs($0.date.timeIntervalSince(h.date)) < 1 && $0.amountOz == h.oz
                    }
                    if !isDuplicate {
                        let new = WaterEntry(amountOz: h.oz)
                        new.date = h.date
                        modelContext.insert(new)
                        addedCount += 1
                    }
                }
                
                // 5. Always Update Goals (latest goal wins)
                if let latestGoal = backup.goals.last {
                    modelContext.insert(DailyGoal(calories: latestGoal.cal, protein: latestGoal.p, carbs: latestGoal.c, fat: latestGoal.f))
                }
                
                try modelContext.save()
                importError = "✅ Merge complete! Added \(addedCount) new items."
            } catch {
                importError = "❌ Import failed: \(error.localizedDescription)"
            }
            
        case .failure(let error):
            importError = "❌ File picker failed: \(error.localizedDescription)"
        }
    }
    
    private func restoreFood(_ f: FoodBackup) -> FoodEntry {
        FoodEntry(name: f.name, brand: f.brand, meal: f.meal, date: f.date, portionGrams: f.grams, portionDescription: f.desc, servings: f.servings, servingUnit: f.unit, calories: f.cals, proteinG: f.p, carbsG: f.c, fatG: f.f, fiberG: f.fiber, rawUserInput: "Restored from backup")
    }
}

