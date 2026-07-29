import Foundation

actor GoalService {

    static func currentGoal(from goals: [DailyGoal]) -> DailyGoal {
        goals
            .filter(\.isActive)
            .max(by: { $0.createdAt < $1.createdAt })
            ?? goals.max(by: { $0.createdAt < $1.createdAt })
            ?? defaultGoal()
    }

    // MARK: - BMR Calculation (Mifflin-St Jeor)

    static func calculateBMR(
        weightLbs: Double,
        heightTotalInches: Int,
        ageYears: Int,
        sex: BiologicalSex
    ) -> Double {
        let kg = weightLbs * 0.453592
        let cm = Double(heightTotalInches) * 2.54

        let bmr: Double
        switch sex {
        case .male:
            bmr = (10 * kg) + (6.25 * cm) - (5 * Double(ageYears)) + 5
        case .female:
            bmr = (10 * kg) + (6.25 * cm) - (5 * Double(ageYears)) - 161
        case .notSpecified:
            let m = (10 * kg) + (6.25 * cm) - (5 * Double(ageYears)) + 5
            let f = (10 * kg) + (6.25 * cm) - (5 * Double(ageYears)) - 161
            bmr = (m + f) / 2
        }

        return bmr
    }

    // MARK: - Maintenance Calories

    static func calculateMaintenanceCalories(
        weightLbs: Double,
        heightTotalInches: Int,
        ageYears: Int,
        sex: BiologicalSex,
        activityProfile: GoalActivityProfile
    ) -> Double {
        let bmr = calculateBMR(
            weightLbs: weightLbs,
            heightTotalInches: heightTotalInches,
            ageYears: ageYears,
            sex: sex
        )

        switch activityProfile.source {
        case .manual:
            let level = activityProfile.manualLevel ?? .moderatelyActive
            return bmr * level.multiplier
        case .appleHealth, .garmin:
            let activeCalories = max(activityProfile.averageActiveCalories ?? 0, 0)
            return bmr + activeCalories
        }
    }

    // MARK: - TDEE Calculation (legacy manual activity path)

    static func calculateTDEE(
        weightLbs: Double,
        heightTotalInches: Int,
        ageYears: Int,
        sex: BiologicalSex,
        activityLevel: ActivityLevel
    ) -> Double {
        calculateMaintenanceCalories(
            weightLbs: weightLbs,
            heightTotalInches: heightTotalInches,
            ageYears: ageYears,
            sex: sex,
            activityProfile: .manual(activityLevel)
        )
    }

    // MARK: - Suggested Calories

    static func calculateSuggestedCalories(
        weightLbs: Double,
        heightInches: Int,
        age: Int,
        sex: BiologicalSex,
        activity: ActivityLevel,
        goal: WeightGoal
    ) -> Double {
        calculateSuggestedCalories(
            weightLbs: weightLbs,
            heightInches: heightInches,
            age: age,
            sex: sex,
            activityProfile: .manual(activity),
            goal: goal
        )
    }

    static func calculateSuggestedCalories(
        weightLbs: Double,
        heightInches: Int,
        age: Int,
        sex: BiologicalSex,
        activityProfile: GoalActivityProfile,
        goal: WeightGoal
    ) -> Double {
        let maintenance = calculateMaintenanceCalories(
            weightLbs: weightLbs,
            heightTotalInches: heightInches,
            ageYears: age,
            sex: sex,
            activityProfile: activityProfile
        )

        switch goal {
        case .loseWeight:  return maintenance - 500   // ~1 lb/week deficit
        case .maintain:    return maintenance
        case .gainMuscle:  return maintenance + 300
        }
    }

    static func dynamicallyAdjustedCalories(
        baseGoalCalories: Double,
        dailyActiveCalories: Double,
        referenceActiveCalories: Double
    ) -> Double {
        guard referenceActiveCalories > 0 else { return baseGoalCalories }
        let adjusted = baseGoalCalories + (dailyActiveCalories - referenceActiveCalories)
        return max(adjusted, 1_000)
    }

    static func displayGoal(
        base: DailyGoal,
        selectedDate: Date,
        activitySource: GoalActivitySource,
        referenceActiveCalories: Double,
        averageActiveCalories: Double?,
        completedDayActiveCalories: Double?,
        calendar: Calendar = .current
    ) -> DailyGoal {
        let calories: Double

        if activitySource == .garmin || activitySource == .appleHealth {
            let activityCalories: Double
            if !calendar.isDateInToday(selectedDate),
               let completedDayActiveCalories {
                activityCalories = completedDayActiveCalories
            } else if let averageActiveCalories, averageActiveCalories > 0 {
                activityCalories = averageActiveCalories
            } else {
                activityCalories = referenceActiveCalories
            }

            calories = dynamicallyAdjustedCalories(
                baseGoalCalories: base.calories,
                dailyActiveCalories: activityCalories,
                referenceActiveCalories: referenceActiveCalories
            )
        } else {
            calories = base.calories
        }

        return DailyGoal(
            calories: calories,
            protein: base.protein,
            carbs: base.carbs,
            fat: base.fat,
            fiber: base.fiber
        )
    }

    // MARK: - Suggested Macros

    static func suggestMacros(
        calories: Double,
        weightLbs: Double,
        goal: WeightGoal
    ) -> (protein: Double, carbs: Double, fat: Double) {
        let proteinG: Double
        switch goal {
        case .loseWeight:  proteinG = weightLbs * 0.85
        case .maintain:    proteinG = weightLbs * 0.75
        case .gainMuscle:  proteinG = weightLbs * 1.0
        }

        let proteinCal = proteinG * 4
        let fatCal     = calories * 0.28
        let fatG       = fatCal / 9
        let carbCal    = calories - proteinCal - fatCal
        let carbG      = max(carbCal / 4, 50)

        return (protein: proteinG, carbs: carbG, fat: fatG)
    }

    // MARK: - Default Goals (for skipped onboarding)

    static func defaultGoal() -> DailyGoal {
        DailyGoal(
            calories: 2000,
            protein: 100,
            carbs: 250,
            fat: 65,
            fiber: 25
        )
    }
}
