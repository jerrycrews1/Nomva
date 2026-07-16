import SwiftUI
import SwiftData

/// Shows the photo the user took/selected, the foods the LLM identified,
/// and lets the user tap each item to adjust servings/meal before logging.
struct PhotoFoodReviewView: View {
    let image: UIImage
    let foods: [RemoteAPIProvider.PhotoFoodItem]
    let meal: String
    let onDone: ([RemoteAPIProvider.PhotoFoodItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loggedIndices: Set<Int> = []
    @State private var selectedFoodIndex: Int? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    photoHeader
                    foodsList
                    progressFooter
                }
                .padding(.vertical)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Photo Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(item: selectedBinding) { selection in
                ManualFoodDetailView(
                    food: foods[selection.index].asFoodItem,
                    meal: meal
                ) {
                    loggedIndices.insert(selection.index)
                    if loggedIndices.count == foods.count {
                        let all = foods
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onDone(all)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var photoHeader: some View {
        VStack(spacing: 8) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)

            Text("Tap each item to adjust servings and meal time")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var foodsList: some View {
        VStack(spacing: 0) {
            ForEach(0..<foods.count, id: \.self) { index in
                PhotoFoodRow(
                    food: foods[index],
                    isLogged: loggedIndices.contains(index),
                    isLast: index == foods.count - 1
                ) {
                    selectedFoodIndex = index
                }
            }
        }
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
    }

    private var progressFooter: some View {
        HStack {
            Text("\(loggedIndices.count) of \(foods.count) logged")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if loggedIndices.count == foods.count {
                Text("All done!")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 24)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .foregroundStyle(.secondary)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                let logged = foods.enumerated()
                    .filter { loggedIndices.contains($0.offset) }
                    .map(\.element)
                onDone(logged)
                dismiss()
            }
            .fontWeight(.semibold)
            .foregroundStyle(.orange)
            .disabled(loggedIndices.isEmpty)
        }
    }

    private var selectedBinding: Binding<SelectedPhotoFood?> {
        Binding(
            get: { selectedFoodIndex.map { SelectedPhotoFood(index: $0) } },
            set: { selectedFoodIndex = $0?.index }
        )
    }
}

// MARK: - Row View (extracted to help the type checker)

private struct PhotoFoodRow: View {
    let food: RemoteAPIProvider.PhotoFoodItem
    let isLogged: Bool
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if !isLogged { onTap() }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(isLogged)

            if !isLast {
                Divider().padding(.leading, 52)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            Image(systemName: isLogged ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(isLogged ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(food.name.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isLogged ? .secondary : .primary)
                Text(food.portion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let calText: String = "\(Int(food.calories)) cal"
            let macroText: String = "\(Int(food.protein))P · \(Int(food.carbs))C · \(Int(food.fat))F"

            VStack(alignment: .trailing, spacing: 2) {
                Text(calText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isLogged ? Color.secondary : Color.orange)
                Text(macroText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !isLogged {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isLogged ? 0.6 : 1)
    }
}

// Identifiable wrapper so .sheet(item:) works
private struct SelectedPhotoFood: Identifiable {
    let index: Int
    var id: Int { index }
}

// Convert a PhotoFoodItem into a FoodItem for ManualFoodDetailView
extension RemoteAPIProvider.PhotoFoodItem {
    var asFoodItem: FoodItem {
        let g = max(grams, 1)
        return FoodItem(
            id: Int.random(in: 100_000...999_999),
            name: name.capitalized,
            servingGrams: g,
            servingDesc: portion,
            caloriesPerServing: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fiberG: fiber ?? 0,
            sugarG: 0,
            sodiumMg: 0
        )
    }
}
