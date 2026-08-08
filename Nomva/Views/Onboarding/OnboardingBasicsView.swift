import SwiftUI

struct OnboardingBasicsView: View {
    @Binding var biologicalSex: BiologicalSex
    @Binding var birthYear: Int
    @Binding var heightFeet: Int
    @Binding var heightInches: Int
    @Binding var currentWeightLbs: Double
    @Binding var activityLevel: ActivityLevel

    @FocusState private var isWeightFocused: Bool

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
                title: "Your starting point",
                subtitle: "These details help Nomva personalize your first daily goals.",
                tone: .hero
            ) {
                HStack(spacing: 10) {
                    profileChip(title: "Age", value: "\(age)")
                    profileChip(title: "Height", value: "\(heightFeet)'\(heightInches)\"")
                    profileChip(title: "Weight", value: "\(currentWeightLbs.formatted(.number.precision(.fractionLength(0...1)))) lb")
                }
            }

            OnboardingSectionCard(
                title: "Body details",
                subtitle: "Use as much or as little as you want. You can edit this later."
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Biological sex")
                            .font(.headline)

                        Picker("Biological Sex", selection: $biologicalSex) {
                            ForEach(BiologicalSex.allCases, id: \.self) { sex in
                                Text(sex == .notSpecified ? "Not specified" : sex.displayName)
                                    .tag(sex)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.large)

                        Text("Optional. This can help fine-tune your starting calories.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Measurements")
                            .font(.headline)
                            .padding(.bottom, 6)

                        measurementRow(title: "Birth year", detail: "Age \(age)") {
                            controlChrome {
                                Picker("Birth Year", selection: $birthYear) {
                                    ForEach((1930...2010).reversed(), id: \.self) { year in
                                        Text(String(year)).tag(year)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }
                        }

                        Divider()

                        measurementRow(
                            title: "Height",
                            detail: "\(heightFeet * 12 + heightInches) inches total"
                        ) {
                            HStack(spacing: 8) {
                                controlChrome {
                                    Picker("Feet", selection: $heightFeet) {
                                        ForEach(4...7, id: \.self) { feet in
                                            Text("\(feet) ft").tag(feet)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }

                                controlChrome {
                                    Picker("Inches", selection: $heightInches) {
                                        ForEach(0...11, id: \.self) { inches in
                                            Text("\(inches) in").tag(inches)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                            }
                        }

                        Divider()

                        measurementRow(title: "Current weight", detail: "Decimals are welcome") {
                            controlChrome {
                                HStack(spacing: 6) {
                                    TextField(
                                        "160",
                                        value: $currentWeightLbs,
                                        format: .number.precision(.fractionLength(0...1))
                                    )
                                    .keyboardType(.decimalPad)
                                    .focused($isWeightFocused)
                                    .font(.title3.weight(.semibold))
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 72)

                                    Text("lb")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            OnboardingSectionCard(
                title: "How active are you?",
                subtitle: "Pick what matches most days. You can change this later or use Apple Health instead."
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isWeightFocused = false
                }
            }
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func measurementRow<Control: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                measurementLabel(title: title, detail: detail)
                Spacer(minLength: 8)
                control()
            }

            VStack(alignment: .leading, spacing: 8) {
                measurementLabel(title: title, detail: detail)
                control()
            }
        }
        .frame(minHeight: 58)
        .padding(.vertical, 2)
    }

    private func measurementLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func controlChrome<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .tint(.primary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(UIColor.separator).opacity(0.35), lineWidth: 1)
            }
    }
}
