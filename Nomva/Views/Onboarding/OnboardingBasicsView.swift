import SwiftUI

struct OnboardingBasicsView: View {
    @Binding var biologicalSex: BiologicalSex
    @Binding var birthYear: Int
    @Binding var heightFeet: Int
    @Binding var heightInches: Int
    @Binding var currentWeightLbs: Double
    @Binding var activityLevel: ActivityLevel

    var onContinue: () -> Void
    var onSkip: () -> Void

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var age: Int {
        currentYear - birthYear
    }

    var body: some View {
        OnboardingShell {
            OnboardingSectionCard(
                title: "Tell us about yourself",
                subtitle: "This stays on your device unless you decide to turn on iCloud sync.",
                tone: .hero
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("We use this to estimate calorie needs and make your daily targets feel less generic.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        profileChip(title: "Age", value: "\(age)")
                        profileChip(title: "Height", value: "\(heightFeet)'\(heightInches)\"")
                        profileChip(title: "Weight", value: "\(currentWeightLbs.formatted(.number.precision(.fractionLength(0...1)))) lb")
                    }
                }
            }

            OnboardingSectionCard(
                title: "Body details",
                subtitle: "Use as much or as little as you want. You can edit this later."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Biological Sex")
                            .font(.headline)

                        Picker("Biological Sex", selection: $biologicalSex) {
                            ForEach(BiologicalSex.allCases, id: \.self) { sex in
                                Text(sex.displayName).tag(sex)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Optional. This only helps estimate calorie needs more accurately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Age & Height")
                            .font(.headline)

                        HStack(spacing: 12) {
                            menuField(title: "Birth Year") {
                                Picker("Birth Year", selection: $birthYear) {
                                    ForEach((1930...2010).reversed(), id: \.self) { year in
                                        Text(String(year)).tag(year)
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            menuField(title: "Feet") {
                                Picker("Feet", selection: $heightFeet) {
                                    ForEach(4...7, id: \.self) { feet in
                                        Text("\(feet) ft").tag(feet)
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            menuField(title: "Inches") {
                                Picker("Inches", selection: $heightInches) {
                                    ForEach(0...11, id: \.self) { inches in
                                        Text("\(inches) in").tag(inches)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current Weight")
                            .font(.headline)

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            TextField("160", value: $currentWeightLbs, format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad)
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .frame(maxWidth: 180)

                            Text("lb")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text("Decimals are fine if you want to be precise.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            OnboardingSectionCard(
                title: "How active are you?",
                subtitle: "Choose the option that best matches most days. You can replace this estimate with Apple Health activity later."
            ) {
                ActivityLevelPicker(selection: $activityLevel)
            }
        } footer: {
            Button("Continue") {
                onContinue()
            }
            .buttonStyle(NomvaPrimaryButtonStyle())

            Button("Skip for Now") {
                onSkip()
            }
            .buttonStyle(NomvaSecondaryButtonStyle())
        }
    }

    private func profileChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func menuField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
