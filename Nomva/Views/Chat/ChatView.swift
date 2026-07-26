import SwiftUI
import SwiftData

struct ChatView: View {
    @Query(sort: \ChatMessage.timestamp)  private var allMessages: [ChatMessage]
    @Query(sort: \FoodEntry.date)         private var allEntries: [FoodEntry]
    @Query(sort: \WeightEntry.date)       private var allWeightEntries: [WeightEntry]
    @Query(sort: \CustomFood.createdAt, order: .reverse) private var customFoods: [CustomFood]
    @Query(sort: \MealTemplate.createdAt, order: .reverse) private var mealTemplates: [MealTemplate]
    @Query(sort: \LoggingSession.updatedAt, order: .reverse) private var loggingSessions: [LoggingSession]
    @Query(sort: \WaterEntry.date)        private var allWaterEntries: [WaterEntry]
    @Query                                private var goals: [DailyGoal]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager)  private var undoManager
    @EnvironmentObject private var routeCenter: NomvaRouteCenter

    @State private var selectedDate      = Date.now
    @State private var inputText         = ""
    @State private var isProcessing      = false
    @State private var showBarcodeScanner = false
    @State private var showClearConfirm  = false
    @State private var showNutritionDetail = false
    @State private var scannedFood: FoodItem? = nil
    @State private var scannerError: String? = nil

    // Photo food logging
    @State private var showPhotoSourcePicker = false
    @State private var showCamera            = false
    @State private var showPhotoLibrary      = false
    @State private var selectedImage: UIImage? = nil
    @State private var isAnalyzingPhoto      = false
    @State private var photoAnalysisResult: [RemoteAPIProvider.PhotoFoodItem]? = nil
    @State private var photoError: String?   = nil
    @State private var showPremiumAlert      = false

    @FocusState private var isInputFocused: Bool

    private let contentInset: CGFloat = NomvaTheme.contentInset
    private let chatBottomID = "chat-bottom"
    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(selectedDate) }

    // MARK: - Computed Properties

    private var dayStart: Date { cal.startOfDay(for: selectedDate) }
    private var dayEnd:   Date { cal.date(byAdding: .day, value: 1, to: dayStart)! }

    private var messages: [ChatMessage] {
        allMessages.filter { $0.dayDate >= dayStart && $0.dayDate < dayEnd }
    }

    private var selectedDayEntries: [FoodEntry] {
        allEntries.filter { $0.date >= dayStart && $0.date < dayEnd }
    }

    private var currentGoal: DailyGoal {
        goals.first ?? GoalService.defaultGoal()
    }

    private var activeLoggingSession: LoggingSession? {
        loggingSessions.first { $0.dayDate >= dayStart && $0.dayDate < dayEnd }
    }

    private var selectedDayTotals: NutritionTotals {
        NutritionTotals.from(entries: selectedDayEntries)
    }

    private let examplePrompts = [
        "Log breakfast: Greek yogurt, blueberries, and coffee",
        "Actually make lunch 4 oz grilled chicken instead",
        "How many calories do I have left?"
    ]

    init() {}

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                NomvaScreenBackground()

                VStack(spacing: NomvaTheme.sectionGap) {
                    Button {
                        showNutritionDetail = true
                    } label: {
                        MacroRingsView(
                            consumed: selectedDayTotals,
                            goal: currentGoal,
                            isCompact: isInputFocused || !messages.isEmpty,
                            showsDetailCue: true
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, contentInset)
                    .padding(.top, NomvaTheme.topCardGap)
                    .animation(.spring(), value: isInputFocused || !messages.isEmpty)
                    .accessibilityHint("Shows detailed nutrition, Daily Value context, and trends")

                    messageList

                    chatInputBar
                        .padding(.horizontal, contentInset)
                        .padding(.bottom, 8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ── Date navigator (centre) ────────────────────────────────
                ToolbarItem(placement: .principal) {
                    dateNavigator
                }
                // ── Clear chat (trailing) ─────────────────────────────────
                if !messages.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Clear \(dateLabel) chat")
                    }
                }
            }
            .alert("Clear \(dateLabel) chat?", isPresented: $showClearConfirm) {
                Button("Clear Chat", role: .destructive) {
                    for msg in messages { modelContext.delete(msg) }
                    for session in loggingSessions where session.dayDate >= dayStart && session.dayDate < dayEnd {
                        modelContext.delete(session)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the conversation but keeps your logged food entries.")
            }
            .sheet(isPresented: $showBarcodeScanner) {
                BarcodeScannerView { barcode in
                    handleBarcode(barcode)
                }
            }
            .sheet(isPresented: $showNutritionDetail) {
                NutritionDetailView(
                    selectedDate: selectedDate,
                    entries: selectedDayEntries,
                    allEntries: allEntries,
                    goal: currentGoal
                )
            }
            .sheet(item: $scannedFood) { food in
                NavigationStack {
                    ManualFoodDetailView(
                        food: food,
                        meal: currentMeal(at: timestampForSelectedDay())
                    )
                }
            }
        } // End of NavigationStack
        .alert("Scan Failed", isPresented: Binding(
            get: { scannerError != nil },
            set: { if !$0 { scannerError = nil } }
        )) {
            Button("OK") { scannerError = nil }
        } message: {
            Text(scannerError ?? "")
        }
        .confirmationDialog("Add Photo", isPresented: $showPhotoSourcePicker, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { showCamera = true }
            }
            Button("Choose from Library") { showPhotoLibrary = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera, onImagePicked: { image in
                handlePickedImage(image)
            }, onCancel: {
                showCamera = false
            })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotoLibrary) {
            ImagePicker(sourceType: .photoLibrary, onImagePicked: { image in
                showPhotoLibrary = false
                handlePickedImage(image)
            }, onCancel: {
                showPhotoLibrary = false
            })
        }
        .sheet(isPresented: Binding(
            get: { photoAnalysisResult != nil && selectedImage != nil },
            set: { if !$0 { photoAnalysisResult = nil; selectedImage = nil } }
        )) {
            if let image = selectedImage, let foods = photoAnalysisResult {
                PhotoFoodReviewView(
                    image: image,
                    foods: foods,
                    meal: currentMeal(at: timestampForSelectedDay())
                ) { loggedFoods in
                    postPhotoSummary(loggedFoods)
                    photoAnalysisResult = nil
                    selectedImage = nil
                }
            }
        }
        .alert("Photo Scan Failed", isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("OK") { photoError = nil }
        } message: {
            Text(photoError ?? "")
        }
        .alert("Premium Feature", isPresented: $showPremiumAlert) {
            Button("OK") {}
        } message: {
            Text("Photo food scanning is a premium feature. Upgrade to scan meals with your camera.")
        }
        .onAppear { modelContext.undoManager = undoManager }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            if isToday { selectedDate = .now }
        }
        .onReceive(routeCenter.$currentRoute.compactMap { $0 }) { route in
            switch route {
            case .chat:
                isInputFocused = true
                routeCenter.clear(route)
            case .barcode:
                showBarcodeScanner = true
                routeCenter.clear(route)
            default:
                break
            }
        }
    }


    // MARK: - Date Navigator

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

    private var dateLabel: String {
        displayLabel(for: selectedDate)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        emptyChatPrompt
                    }

                    ForEach(messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }

                    if isProcessing {
                        HStack { TypingIndicator(); Spacer() }
                            .padding(.horizontal)
                            .id("typing")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(chatBottomID)
                }
                .padding(.horizontal, contentInset)
                .padding(.top, messages.isEmpty ? 6 : 0)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollToLatestMessage(using: proxy, animated: false)
            }
            .onChange(of: messages.map(\.id)) {
                scrollToLatestMessage(using: proxy)
            }
            .onChange(of: isProcessing) {
                scrollToLatestMessage(using: proxy)
            }
            .onChange(of: selectedDate) {
                scrollToLatestMessage(using: proxy, animated: false)
            }
        }
    }

    private func scrollToLatestMessage(using proxy: ScrollViewProxy, animated: Bool = true) {
        let scroll = {
            proxy.scrollTo(chatBottomID, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.25), scroll)
        } else {
            scroll()
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25), scroll)
            } else {
                scroll()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if animated {
                withAnimation(.easeOut(duration: 0.25), scroll)
            } else {
                scroll()
            }
        }
    }

    // MARK: - Empty State

    private var emptyChatPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isToday ? "Log food in one message." : "Log food for \(dateLabel).")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                Text("Log a meal, fix an entry, or check what's left.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(examplePrompts.prefix(2)), id: \.self) { prompt in
                        suggestionChip(prompt)
                    }
                }
            }
            .nomvaCard(.subtle, padding: NomvaTheme.standardCardPadding)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            inputText = text
            sendMessage()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NomvaTheme.accent)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bar

    private var chatInputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isToday {
                NomvaTag(text: "Adding to \(dateLabel)", tint: NomvaTheme.accent)
            }

            HStack(spacing: 10) {
                // Camera / photo button
                Button {
                    if SubscriptionManager.shared.isPremium {
                        showPhotoSourcePicker = true
                    } else {
                        showPremiumAlert = true
                    }
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: NomvaTheme.iconControlSize, height: NomvaTheme.iconControlSize)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(Circle())
                }
                .padding(2)
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)

                // Barcode scanner button
                Button {
                    showBarcodeScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: NomvaTheme.iconControlSize, height: NomvaTheme.iconControlSize)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(Circle())
                }
                .padding(2)
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)

                HStack(alignment: .bottom, spacing: 10) {
                    TextField(
                        isToday ? "What did you eat?" : "What did you eat on \(dateLabel)?",
                        text: $inputText,
                        axis: .vertical
                    )
                    .font(.body)
                    .lineLimit(isInputFocused ? 1...4 : 1...2)
                    .focused($isInputFocused)
                    .padding(.vertical, isInputFocused ? 11 : 10)

                    Button { sendMessage() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(canSend ? NomvaTheme.accent : .secondary.opacity(0.3))
                            .frame(width: NomvaTheme.iconControlSize, height: NomvaTheme.iconControlSize)
                    }
                    .disabled(!canSend)
                    .scaleEffect(canSend ? 1.0 : 0.92)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: canSend)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(minHeight: NomvaTheme.secondaryControlHeight)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 5)
            }
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    // MARK: - Send

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let targetDate = selectedDate
        let targetDayStart = dayStart
        let targetEntries = selectedDayEntries
        let targetDateLabel = displayLabel(for: targetDate)

        isInputFocused = false
        inputText = ""
        isProcessing = true

        // Save user message immediately so it appears in the UI
        let userMsg = ChatMessage(
            role: "user",
            content: text,
            timestamp: timestamp(for: targetDayStart),
            dayDate: targetDayStart
        )
        modelContext.insert(userMsg)

        // Build conversation context from the last 6 messages
        let recentMsgs = messages
            .filter { $0.role == "user" || $0.role == "assistant" }
            .suffix(6)
            .map { (role: $0.role, content: $0.content) }

        // Pass the last 30 days of food + all weight entries so the LLM can
        // answer "this week", "yesterday", "what's my trend" etc.
        let thirtyDaysAgo  = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        let recentSnapshot = allEntries.filter { $0.date >= thirtyDaysAgo }
        let weightSnapshot = allWeightEntries
        let waterSnapshot  = allWaterEntries
        let goalSnapshot   = currentGoal
        let sessionSnapshot = activeLoggingSession?.decodedState

        Task { @MainActor in
            let result = await FoodLoggingService.shared.process(
                userMessage: text,
                recentMessages: recentMsgs,
                goals: goalSnapshot,
                targetDate: targetDate,
                targetEntries: targetEntries,
                recentEntries: recentSnapshot,
                customFoods: customFoods,
                weightEntries: weightSnapshot,
                waterEntries: waterSnapshot,
                mealTemplates: mealTemplates,
                sessionState: sessionSnapshot
            )

            syncLoggingSession(with: result, dayStart: targetDayStart)
            let assistantReply = applyAction(
                result,
                targetDayStart: targetDayStart,
                targetEntries: targetEntries,
                targetDateLabel: targetDateLabel
            )
            persistTrace(from: result, finalReply: assistantReply, dayStart: targetDayStart)
            
            // Record usage for free trial tracking
            SubscriptionManager.shared.recordAIMessage()

            let assistantMsg = ChatMessage(
                role: "assistant",
                content: assistantReply,
                timestamp: timestamp(for: targetDayStart, offsetBy: 1),
                dayDate: targetDayStart
            )
            modelContext.insert(assistantMsg)

            isProcessing = false
        }
    }

    private func syncLoggingSession(with result: FoodLoggingService.LoggingResult, dayStart: Date) {
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let daySessions = loggingSessions.filter { $0.dayDate >= dayStart && $0.dayDate < dayEnd }

        if result.clearSession {
            for session in daySessions {
                modelContext.delete(session)
            }
        }

        guard let state = result.sessionState else { return }

        if let existing = daySessions.first {
            existing.apply(state: state)
        } else {
            modelContext.insert(LoggingSession(dayDate: dayStart, state: state))
        }
    }

    // MARK: - Apply Action

    /// Performs any model data mutations and returns the final reply string for display.
    private func applyAction(
        _ result: FoodLoggingService.LoggingResult,
        targetDayStart: Date,
        targetEntries: [FoodEntry],
        targetDateLabel: String
    ) -> String {
        switch result.action {

        case .logFood(let entries):
            for (index, entry) in entries.enumerated() {
                entry.date = timestamp(for: targetDayStart, offsetBy: TimeInterval(index))
                modelContext.insert(entry)
            }
            persistEvidence(result.evidenceDrafts, for: entries, dayStart: targetDayStart)
            return result.reply

        case .replaceEntry(let deleteName, let newEntries):
            // Remove the wrong item if found
            var removedName: String? = nil
            if let match = findEntry(named: deleteName, in: targetEntries) {
                removedName = match.name
                modelContext.delete(match)
            }
            // Log the correct items
            for (index, entry) in newEntries.enumerated() {
                entry.date = timestamp(for: targetDayStart, offsetBy: TimeInterval(index))
                modelContext.insert(entry)
            }
            persistEvidence(result.evidenceDrafts, for: newEntries, dayStart: targetDayStart)
            let lines = newEntries.map { "✓ \($0.name) (\($0.portionDescription)) — \(Int($0.calories)) cal" }
            let removed = removedName.map { "Removed \($0).\n" } ?? ""
            return removed + lines.joined(separator: "\n")

        case .replaceEntryById(let deleteId, let newEntries):
            var removedName: String? = nil
            if let match = targetEntries.first(where: { $0.id == deleteId }) {
                removedName = match.name
                modelContext.delete(match)
            }
            for (index, entry) in newEntries.enumerated() {
                entry.date = timestamp(for: targetDayStart, offsetBy: TimeInterval(index))
                modelContext.insert(entry)
            }
            persistEvidence(result.evidenceDrafts, for: newEntries, dayStart: targetDayStart)
            let lines = newEntries.map { "✓ \($0.name) (\($0.portionDescription)) — \(Int($0.calories)) cal" }
            let removed = removedName.map { "Removed \($0).\n" } ?? ""
            return removed + lines.joined(separator: "\n")

        case .log_weight(let entry):
            entry.date = timestamp(for: targetDayStart)
            modelContext.insert(entry)
            return result.reply
            
        case .updateWeight(let idStr, let weightLbs):
            // Find the weight entry by checking if its UUID string starts with the provided ID
            if let existing = allWeightEntries.first(where: { $0.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(idStr.lowercased()) }) {
                existing.weightLbs = weightLbs
            }
            return result.reply

        case .deleteWeight(let idStr):
            // Find the weight entry by shortened ID match
            let toDelete = allWeightEntries.filter { $0.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(idStr.lowercased()) }
            for entry in toDelete { modelContext.delete(entry) }
            return result.reply

        case .deleteAllWeights:
            for entry in allWeightEntries { modelContext.delete(entry) }
            return result.reply

        case .deleteEntries(let ids):
            let targetIds = Set(ids)
            let toDelete = targetEntries.filter { targetIds.contains($0.id) }
            guard !toDelete.isEmpty else { return "Nothing found to remove." }

            for entry in toDelete { modelContext.delete(entry) }
            return "Removed: \(displayNames(for: toDelete))."

        case .editEntry(let name, let newGrams, let newDesc, let newServings, let newServingUnit):
            // Find the best matching entry in the selected day's log
            if let match = findEntry(named: name, in: targetEntries) {
                let factor = newGrams / 100
                match.portionGrams       = newGrams
                match.portionDescription = newDesc
                match.servings = newServings
                match.servingUnit = newServingUnit
                match.calories  = match.caloriesPer100g * factor
                match.proteinG  = match.proteinPer100g  * factor
                match.carbsG    = match.carbsPer100g    * factor
                match.fatG      = match.fatPer100g      * factor
                match.fiberG    = match.fiberPer100g    * factor
                match.sugarG    = match.sugarPer100g    * factor
                match.sodiumMg  = match.sodiumPer100g   * factor
                match.saturatedFatG = match.saturatedFatPer100g.map { $0 * factor }
                match.transFatG = match.transFatPer100g.map { $0 * factor }
                match.cholesterolMg = match.cholesterolPer100g.map { $0 * factor }
                match.addedSugarG = match.addedSugarPer100g.map { $0 * factor }
                match.vitaminDMcg = match.vitaminDPer100g.map { $0 * factor }
                match.calciumMg = match.calciumPer100g.map { $0 * factor }
                match.ironMg = match.ironPer100g.map { $0 * factor }
                match.potassiumMg = match.potassiumPer100g.map { $0 * factor }
                match.vitaminAMcgRAE = match.vitaminAPer100g.map { $0 * factor }
                match.vitaminCMg = match.vitaminCPer100g.map { $0 * factor }
                match.vitaminB12Mcg = match.vitaminB12Per100g.map { $0 * factor }
                match.folateMcgDFE = match.folatePer100g.map { $0 * factor }
                match.magnesiumMg = match.magnesiumPer100g.map { $0 * factor }
                match.zincMg = match.zincPer100g.map { $0 * factor }
                return "Updated \(match.name) to \(newDesc) — \(Int(match.calories)) cal"
            } else {
                return "Couldn't find \"\(name)\" in your \(targetDateLabel.lowercased()) log. Check the Log tab to see what's there."
            }

        case .deleteEntry(let names):
            var removed: [FoodEntry] = []
            var notFound: [String] = []
            var remainingEntries = targetEntries
            var seenTargets: Set<String> = []

            for name in names {
                let normalizedName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedName.isEmpty, seenTargets.insert(normalizedName).inserted else { continue }

                let matches = findEntries(named: name, in: remainingEntries)
                if !matches.isEmpty {
                    removed.append(contentsOf: matches)
                    let matchIds = Set(matches.map(\.id))
                    remainingEntries.removeAll { matchIds.contains($0.id) }
                    for match in matches {
                        modelContext.delete(match)
                    }
                } else {
                    notFound.append(name)
                }
            }
            var reply = removed.isEmpty ? "" : "Removed: \(displayNames(for: removed))."
            if !notFound.isEmpty { reply += (reply.isEmpty ? "" : " ") + "Couldn't find: \(notFound.joined(separator: ", "))." }
            return reply.isEmpty ? "Nothing found to remove." : reply

        case .deleteMeal(let meal):
            let mealLower = meal.lowercased().trimmingCharacters(in: .whitespaces)
            let toDelete: [FoodEntry]
            let mutationDateLabel = absoluteDateLabel(for: targetDayStart)
            
            if ["all", "day", "today"].contains(mealLower) {
                toDelete = targetEntries
            } else {
                toDelete = targetEntries.filter { $0.meal.lowercased() == mealLower }
            }
            
            if toDelete.isEmpty {
                return mealLower == "all"
                    ? "\(mutationDateLabel) is already empty."
                    : "No \(meal) entries found for \(mutationDateLabel)."
            }
            
            for entry in toDelete { modelContext.delete(entry) }
            let count = toDelete.count
            return mealLower == "all"
                ? "✓ Cleared all \(count) item\(count == 1 ? "" : "s") from \(mutationDateLabel)."
                : "✓ Removed \(count) \(meal) item\(count == 1 ? "" : "s") from \(mutationDateLabel)."

        case .logWater(let oz):
            let entry = WaterEntry(amountOz: oz)
            entry.date = timestamp(for: targetDayStart)
            modelContext.insert(entry)
            return result.reply

        case .deleteWater:
            let todayWater = allWaterEntries.filter { $0.date >= targetDayStart && $0.date < cal.date(byAdding: .day, value: 1, to: targetDayStart)! }
            for entry in todayWater { modelContext.delete(entry) }
            return result.reply

        case .setWaterTotal(let oz):
            let todayWater = allWaterEntries.filter { $0.date >= targetDayStart && $0.date < cal.date(byAdding: .day, value: 1, to: targetDayStart)! }
            for entry in todayWater { modelContext.delete(entry) }
            if oz > 0 {
                let entry = WaterEntry(amountOz: oz)
                entry.date = timestamp(for: targetDayStart)
                modelContext.insert(entry)
            }
            return result.reply

        case .setGoal(let calories, let protein, let carbs, let fat, let fiber):
            let goal = currentGoal
            if let v = calories { goal.calories = v }
            if let v = protein  { goal.protein  = v }
            if let v = carbs    { goal.carbs     = v }
            if let v = fat      { goal.fat       = v }
            if let v = fiber    { goal.fiber     = v }
            var parts: [String] = []
            if let v = calories { parts.append("\(Int(v)) cal") }
            if let v = protein  { parts.append("\(Int(v))g protein") }
            if let v = carbs    { parts.append("\(Int(v))g carbs") }
            if let v = fat      { parts.append("\(Int(v))g fat") }
            if let v = fiber    { parts.append("\(Int(v))g fiber") }
            return "Goals updated: \(parts.joined(separator: ", "))."

        case .askClarification(let text):
            return text

        case .reply(let text):
            return text
        }
    }

    private func persistTrace(from result: FoodLoggingService.LoggingResult, finalReply: String, dayStart: Date) {
        guard var draft = result.trace else { return }
        draft.finalReply = finalReply
        modelContext.insert(AgentTraceRecord(
            dayDate: dayStart,
            userMessage: draft.userMessage,
            detectedIntent: draft.detectedIntent,
            providerType: draft.providerType,
            usedFallback: draft.usedFallback,
            rawModelAction: draft.rawModelAction,
            routedAction: draft.routedAction,
            finalAction: draft.finalAction,
            validationSummary: draft.validationSummary,
            searchSummary: draft.searchSummary,
            candidateSummary: draft.candidateSummary,
            rawModelResponse: draft.rawModelResponse,
            finalReply: draft.finalReply
        ))
    }

    private func persistEvidence(
        _ drafts: [FoodLoggingService.ResolvedFoodEvidenceDraft],
        for entries: [FoodEntry],
        dayStart: Date
    ) {
        guard !drafts.isEmpty, drafts.count == entries.count else { return }
        for (draft, entry) in zip(drafts, entries) {
            modelContext.insert(ResolvedFoodEvidence(
                dayDate: dayStart,
                foodEntryId: entry.id,
                sourceType: draft.sourceType,
                fdcId: draft.fdcId,
                matchedName: draft.matchedName,
                matchedBrand: draft.matchedBrand,
                searchTerms: draft.searchTerms,
                candidateSummary: draft.candidateSummary,
                resolutionConfidence: draft.resolutionConfidence,
                wasClarified: draft.wasClarified
            ))
        }
    }

    // MARK: - Fuzzy Name Matching

    /// Finds an entry whose name most closely matches the given string.
    private func findEntry(named target: String, in entries: [FoodEntry]) -> FoodEntry? {
        let t = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        func fullName(_ entry: FoodEntry) -> String {
            let brand = entry.brand ?? ""
            return brand.isEmpty ? entry.name.lowercased() : "\(brand) \(entry.name)".lowercased()
        }

        // 1. Exact match (name or full name)
        if let exact = entries.first(where: { $0.name.lowercased() == t || fullName($0) == t }) {
            return exact
        }

        // 2. Exact match (brand) — if the user only said the brand and it's unique
        let brandMatches = entries.filter { $0.brand?.lowercased() == t }
        if brandMatches.count == 1 { return brandMatches.first }

        // 3. Contains match
        if let contains = entries.first(where: {
            fullName($0).contains(t) || t.contains($0.name.lowercased())
        }) {
            return contains
        }

        // 4. Word overlap — find entry with most words in common
        let targetWords = Set(t.components(separatedBy: .whitespaces).filter { $0.count > 2 })
        if targetWords.isEmpty { return nil }

        return entries
            .map { entry -> (FoodEntry, Int) in
                let combined = "\(entry.brand ?? "") \(entry.name)".lowercased()
                let entryWords = Set(combined.components(separatedBy: .whitespaces))
                return (entry, entryWords.intersection(targetWords).count)
            }
            .filter { $0.1 > 0 }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    private func findEntries(named target: String, in entries: [FoodEntry]) -> [FoodEntry] {
        let t = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }

        func fullName(_ entry: FoodEntry) -> String {
            let brand = entry.brand ?? ""
            return brand.isEmpty ? entry.name.lowercased() : "\(brand) \(entry.name)".lowercased()
        }

        let exactMatches = entries.filter { $0.name.lowercased() == t || fullName($0) == t }
        if !exactMatches.isEmpty { return exactMatches }

        let brandMatches = entries.filter { $0.brand?.lowercased() == t }
        if !brandMatches.isEmpty { return brandMatches }

        let containsMatches = entries.filter {
            fullName($0).contains(t) || t.contains($0.name.lowercased())
        }
        if !containsMatches.isEmpty { return containsMatches }

        return findEntry(named: target, in: entries).map { [$0] } ?? []
    }

    private func displayNames(for entries: [FoodEntry]) -> String {
        let counts = Dictionary(grouping: entries, by: \.name).mapValues { $0.count }
        return counts.keys.sorted().map { name in
            let count = counts[name] ?? 1
            return count > 1 ? "\(name) x\(count)" : name
        }
        .joined(separator: ", ")
    }

    // MARK: - Quick Add (from recent foods chips)

    private func quickAdd(entry: FoodEntry) {
        let newEntry = FoodEntry(
            name: entry.name,
            brand: entry.brand,
            meal: currentMeal(at: timestampForSelectedDay()),
            date: timestampForSelectedDay(),
            portionGrams: entry.portionGrams,
            portionDescription: entry.portionDescription,
            calories: entry.calories,
            proteinG: entry.proteinG,
            carbsG: entry.carbsG,
            fatG: entry.fatG,
            fiberG: entry.fiberG,
            sugarG: entry.sugarG,
            sodiumMg: entry.sodiumMg,
            saturatedFatG: entry.saturatedFatG,
            transFatG: entry.transFatG,
            cholesterolMg: entry.cholesterolMg,
            addedSugarG: entry.addedSugarG,
            vitaminDMcg: entry.vitaminDMcg,
            calciumMg: entry.calciumMg,
            ironMg: entry.ironMg,
            potassiumMg: entry.potassiumMg,
            vitaminAMcgRAE: entry.vitaminAMcgRAE,
            vitaminCMg: entry.vitaminCMg,
            vitaminB12Mcg: entry.vitaminB12Mcg,
            folateMcgDFE: entry.folateMcgDFE,
            magnesiumMg: entry.magnesiumMg,
            zincMg: entry.zincMg,
            caloriesPer100g: entry.caloriesPer100g,
            proteinPer100g: entry.proteinPer100g,
            carbsPer100g: entry.carbsPer100g,
            fatPer100g: entry.fatPer100g,
            fiberPer100g: entry.fiberPer100g,
            sugarPer100g: entry.sugarPer100g,
            sodiumPer100g: entry.sodiumPer100g,
            saturatedFatPer100g: entry.saturatedFatPer100g,
            transFatPer100g: entry.transFatPer100g,
            cholesterolPer100g: entry.cholesterolPer100g,
            addedSugarPer100g: entry.addedSugarPer100g,
            vitaminDPer100g: entry.vitaminDPer100g,
            calciumPer100g: entry.calciumPer100g,
            ironPer100g: entry.ironPer100g,
            potassiumPer100g: entry.potassiumPer100g,
            vitaminAPer100g: entry.vitaminAPer100g,
            vitaminCPer100g: entry.vitaminCPer100g,
            vitaminB12Per100g: entry.vitaminB12Per100g,
            folatePer100g: entry.folatePer100g,
            magnesiumPer100g: entry.magnesiumPer100g,
            zincPer100g: entry.zincPer100g,
            rawUserInput: "Quick add: \(entry.name)",
            fdcId: entry.fdcId,
            foodDatabaseId: entry.foodDatabaseId,
            source: entry.source,
            barcode: entry.barcode
        )
        modelContext.insert(newEntry)

        let msg = ChatMessage(
            role: "assistant",
            content: "✓ Added \(entry.name) (\(entry.portionDescription)) — \(Int(entry.calories)) cal",
            timestamp: timestampForSelectedDay(offsetBy: 1),
            dayDate: dayStart
        )
        modelContext.insert(msg)
    }

    // MARK: - Barcode

    private func handleBarcode(_ barcode: String) {
        showBarcodeScanner = false
        Task { @MainActor in
            switch await BarcodeLookupService.shared.lookup(barcode: barcode) {
            case let .found(food, _):
                scannedFood = food
            case .notFound:
                scannerError = "Couldn’t find barcode \(barcode) in Nomva’s local food database yet. Try typing the food name instead."
            case .unavailable:
                scannerError = "Couldn’t look up barcode \(barcode) from the local food database right now. Try typing the food name instead."
            }
        }
    }

    // MARK: - Photo Analysis

    private func handlePickedImage(_ image: UIImage) {
        showCamera = false
        selectedImage = image
        isAnalyzingPhoto = true
        isProcessing = true

        // Show a user message in chat for the photo
        let userMsg = ChatMessage(
            role: "user",
            content: "📷 Scanning food photo…",
            timestamp: timestamp(for: dayStart),
            dayDate: dayStart
        )
        modelContext.insert(userMsg)

        Task { @MainActor in
            do {
                // Compress to JPEG, max 1024px wide, ~0.7 quality
                let resized = resizeImage(image, maxDimension: 1024)
                guard let jpegData = resized.jpegData(compressionQuality: 0.7) else {
                    throw NSError(domain: "Nomva", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not compress image"])
                }
                let base64 = jpegData.base64EncodedString()

                let provider = RemoteAPIProvider(baseURL: NomvaAPI.baseURL)
                let result = try await provider.analyzePhoto(imageBase64: base64)

                if result.notFood == true || result.foods.isEmpty {
                    let reply = ChatMessage(
                        role: "assistant",
                        content: "I couldn't identify any food in that photo. Try taking a clearer picture of your meal.",
                        timestamp: timestamp(for: dayStart, offsetBy: 1),
                        dayDate: dayStart
                    )
                    modelContext.insert(reply)
                    selectedImage = nil
                } else {
                    photoAnalysisResult = result.foods
                }
            } catch {
                photoError = "Couldn't analyze the photo: \(error.localizedDescription)"
                selectedImage = nil
            }

            isAnalyzingPhoto = false
            isProcessing = false
            SubscriptionManager.shared.recordAIMessage()
        }
    }

    /// Posts a chat summary after the user finishes logging photo-scanned foods.
    /// ManualFoodDetailView already inserted the FoodEntry objects.
    private func postPhotoSummary(_ foods: [RemoteAPIProvider.PhotoFoodItem]) {
        guard !foods.isEmpty else { return }
        let targetDayStart = dayStart
        let lines = foods.map { "✓ \($0.name.capitalized) (\($0.portion)) — \(Int($0.calories)) cal" }
        let totalCal = foods.reduce(0) { $0 + Int($1.calories) }
        let reply = lines.joined(separator: "\n") + "\n\nTotal: \(totalCal) cal"
        let assistantMsg = ChatMessage(
            role: "assistant",
            content: reply,
            timestamp: timestamp(for: targetDayStart, offsetBy: 1),
            dayDate: targetDayStart
        )
        modelContext.insert(assistantMsg)
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Helpers

    private func currentMeal(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11:  return "breakfast"
        case 11..<15: return "lunch"
        case 15..<20: return "dinner"
        default:      return "snack"
        }
    }

    private func timestampForSelectedDay(offsetBy seconds: TimeInterval = 0) -> Date {
        timestamp(for: dayStart, offsetBy: seconds)
    }

    private func timestamp(for dayStart: Date, offsetBy seconds: TimeInterval = 0) -> Date {
        let reference = Date.now.addingTimeInterval(seconds)
        let components = cal.dateComponents([.hour, .minute, .second], from: reference)
        return cal.date(
            bySettingHour: components.hour ?? 12,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            of: dayStart
        ) ?? dayStart.addingTimeInterval(seconds)
    }

    private func displayLabel(for date: Date) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: .now)
            ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func absoluteDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    var isUser: Bool { message.role == "user" }
    var isScanner: Bool { message.role == "scanner" }
    private var title: String { isScanner ? "Scanner" : "Nomva" }
    private var leadingIcon: String { isScanner ? "barcode.viewfinder" : "sparkles" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !isUser {
                Image(systemName: leadingIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isScanner ? .secondary : NomvaTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 38)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(bubbleBackground)
                    .foregroundColor(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 290, alignment: isUser ? .trailing : .leading)

            if isUser {
                Image(systemName: "person.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(NomvaTheme.accentGradient)
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 38)
            }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isUser {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(NomvaTheme.accentGradient)
        } else if isScanner {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(UIColor.tertiarySystemBackground).opacity(0.96))
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.82))
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .offset(y: animating ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever()
                        .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { animating = true }
    }
}

// MARK: - Rounded Corner Helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RoundedCornerShape: Shape {
    let radius: CGFloat
    let corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    ChatView()
        .environmentObject(NomvaRouteCenter.shared)
}
