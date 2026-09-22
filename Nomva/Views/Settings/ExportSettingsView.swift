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
    @State private var recoveryArchives: [URL] = []
    @State private var pendingRecovery: URL?
    
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
                            .tint(NomvaTheme.accent)
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
                                guard NomvaPersistence.save(modelContext) else { return }
                                let data = filteredData
                                if let url = ExportService.shared.generateCoachReport(
                                    entries: data.foods,
                                    weights: data.weights,
                                    water: data.water,
                                    goals: goals,
                                    detailLevel: reportDetail
                                ) {
                                    shareFile(url: url)
                                } else {
                                    importError = "The report could not be created. Check available storage and try again."
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                    Text("Generate CSV Report")
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .padding()
                                .background(NomvaTheme.accent.opacity(0.1))
                                .foregroundColor(NomvaTheme.accent)
                                .cornerRadius(12)
                            }
                        }
                    }
                    
                    SettingsSectionCard("Full App Backup", detail: "Keep a copy outside Nomva before changing phones or reinstalling. App history stays on this device and is excluded from automatic device backup. Exported files contain personal nutrition and health information; choose a destination you trust.") {
                        VStack(spacing: 12) {
                            Button {
                                guard NomvaPersistence.save(modelContext) else { return }
                                if let url = ExportService.shared.generateBackup() {
                                    shareFile(url: url)
                                } else {
                                    importError = "The backup could not be created. Check available storage and try again."
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "archivebox.fill")
                                    Text("Export JSON Backup")
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .padding()
                                .background(NomvaTheme.info.opacity(0.1))
                                .foregroundColor(NomvaTheme.info)
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
                                .background(NomvaTheme.success.opacity(0.1))
                                .foregroundColor(NomvaTheme.success)
                                .cornerRadius(12)
                            }
                        }
                    }
                    
                    if let error = importError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(NomvaTheme.danger)
                            .padding()
                    }
                    if !recoveryArchives.isEmpty {
                        SettingsSectionCard("Local Recovery", detail: "Return to the saved state from before a previous restore. These copies remain on this device.") {
                            ForEach(recoveryArchives, id: \.self) { url in
                                Button(recoveryLabel(for: url)) {
                                    pendingRecovery = url
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Backup & Export")
        .task { recoveryArchives = (try? SyncMigrationService.recoveryArchives()) ?? [] }
        .confirmationDialog("Restore this earlier local state?", isPresented: Binding(
            get: { pendingRecovery != nil }, set: { if !$0 { pendingRecovery = nil } }
        ), titleVisibility: .visible) {
            Button("Restore Earlier State", role: .destructive) {
                guard let url = pendingRecovery else { return }
                do {
                    try modelContext.save()
                    let archive = try SyncMigrationService.readRecoveryArchive(url)
                    let current = try SyncMigrationService.captureArchive(from: modelContext.container, storeKind: ModelContainerManager.shared.activeStoreKind)
                    _ = try SyncMigrationService.writeArchive(current, reason: "before-restore")
                    _ = try SyncMigrationService.replaceStore(with: archive, in: modelContext.container)
                    importError = "Earlier local state restored. Your previous state is kept in Local Recovery."
                    recoveryArchives = try SyncMigrationService.recoveryArchives()
                } catch { importError = "Recovery failed: \(error.localizedDescription)" }
                pendingRecovery = nil
            }
        } message: { Text("This replaces the current local history. A recovery copy of the current state is saved first. It does not roll back changes already made in Apple Health.") }
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

    private func recoveryLabel(for url: URL) -> String {
        guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return "Saved state before restore" }
        return "Before restore · " + created.formatted(date: .abbreviated, time: .shortened)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Security: Request access to the file
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            
            do {
                // Preserve a recovery copy before merging an older archive.
                try modelContext.save()
                let before = try SyncMigrationService.captureArchive(from: modelContext.container, storeKind: ModelContainerManager.shared.activeStoreKind)
                _ = try SyncMigrationService.writeArchive(before, reason: "before-restore")
                let data = try Data(contentsOf: url)
                let backup = try JSONDecoder().decode(ExportService.BackupData.self, from: data)

                if let archive = backup.archive {
                    let counts = try SyncMigrationService.merge(
                        archive: archive,
                        into: ModelContainerManager.shared.container
                    )
                    importError = "Merge complete. Restored \(counts.totalTouched) records."
                    recoveryArchives = try SyncMigrationService.recoveryArchives()
                    return
                }
                
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
                importError = "Merge complete. Added \(addedCount) new items."
            } catch {
                modelContext.rollback()
                importError = "Import failed: \(error.localizedDescription)"
            }
            
        case .failure(let error):
            importError = "File picker failed: \(error.localizedDescription)"
        }
    }
    
    private func restoreFood(_ f: FoodBackup) -> FoodEntry {
        FoodEntry(name: f.name, brand: f.brand, meal: f.meal, date: f.date, portionGrams: f.grams, portionDescription: f.desc, servings: f.servings, servingUnit: f.unit, calories: f.cals, proteinG: f.p, carbsG: f.c, fatG: f.f, fiberG: f.fiber, rawUserInput: "Restored from backup")
    }
}
