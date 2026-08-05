import Foundation

struct GoalProjection: Equatable {
    let restingCalories: Double
    let activityCalories: Double
    let maintenanceCalories: Double
    let requestedAdjustmentCalories: Double
    let appliedAdjustmentCalories: Double
    let targetCalories: Double
    let minimumCaloriesApplied: Bool
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let proteinGramsPerPound: Double
    let fatCaloriePercentage: Double
}

actor GoalService {

    static let minimumSuggestedCalories = 1_000.0
    static let fatCalorieFraction = 0.28

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
        calculateProjection(
            weightLbs: weightLbs,
            heightInches: heightInches,
            age: age,
            sex: sex,
            activityProfile: activityProfile,
            goal: goal
        ).targetCalories
    }

    static func calculateProjection(
        weightLbs: Double,
        heightInches: Int,
        age: Int,
        sex: BiologicalSex,
        activityProfile: GoalActivityProfile,
        goal: WeightGoal
    ) -> GoalProjection {
        let resting = calculateBMR(
            weightLbs: weightLbs,
            heightTotalInches: heightInches,
            ageYears: age,
            sex: sex
        )
        let maintenance = calculateMaintenanceCalories(
            weightLbs: weightLbs,
            heightTotalInches: heightInches,
            ageYears: age,
            sex: sex,
            activityProfile: activityProfile
        )
        let requestedAdjustment = requestedCalorieAdjustment(for: goal)
        let unconstrainedTarget = maintenance + requestedAdjustment
        let target = max(unconstrainedTarget, minimumSuggestedCalories).rounded()
        let macros = suggestMacros(calories: target, weightLbs: weightLbs, goal: goal)

        return GoalProjection(
            restingCalories: resting,
            activityCalories: max(maintenance - resting, 0),
            maintenanceCalories: maintenance,
            requestedAdjustmentCalories: requestedAdjustment,
            appliedAdjustmentCalories: target - maintenance,
            targetCalories: target,
            minimumCaloriesApplied: unconstrainedTarget < minimumSuggestedCalories,
            protein: macros.protein,
            carbs: macros.carbs,
            fat: macros.fat,
            fiber: suggestFiber(calories: target),
            proteinGramsPerPound: proteinGramsPerPound(for: goal),
            fatCaloriePercentage: fatCalorieFraction * 100
        )
    }

    static func requestedCalorieAdjustment(for goal: WeightGoal) -> Double {
        switch goal {
        case .loseWeight: -500
        case .maintain: 0
        case .gainMuscle: 300
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

    /// Keeps a partial day from lowering the goal while still crediting activity
    /// above the user's recent completed-day baseline.
    static func sameDayAdjustedCalories(
        baseGoalCalories: Double,
        currentDayActiveCalories: Double?,
        rollingAverageActiveCalories: Double?,
        referenceActiveCalories: Double
    ) -> Double {
        guard referenceActiveCalories > 0 else { return baseGoalCalories }

        let rollingBaseline = rollingAverageActiveCalories.flatMap { $0 > 0 ? $0 : nil }
            ?? referenceActiveCalories
        let currentActivity = max(currentDayActiveCalories ?? 0, 0)
        let creditedActivity = max(rollingBaseline, currentActivity)

        return dynamicallyAdjustedCalories(
            baseGoalCalories: baseGoalCalories,
            dailyActiveCalories: creditedActivity,
            referenceActiveCalories: referenceActiveCalories
        )
    }

    static func displayGoal(
        base: DailyGoal,
        selectedDate: Date,
        activitySource: GoalActivitySource,
        referenceActiveCalories: Double,
        averageActiveCalories: Double?,
        currentDayActiveCalories: Double?,
        completedDayActiveCalories: Double?,
        calendar: Calendar = .current
    ) -> DailyGoal {
        let calories: Double

        if activitySource == .garmin || activitySource == .appleHealth {
            if calendar.isDateInToday(selectedDate) {
                calories = sameDayAdjustedCalories(
                    baseGoalCalories: base.calories,
                    currentDayActiveCalories: currentDayActiveCalories,
                    rollingAverageActiveCalories: averageActiveCalories,
                    referenceActiveCalories: referenceActiveCalories
                )
            } else {
                let activityCalories = completedDayActiveCalories
                    ?? averageActiveCalories.flatMap { $0 > 0 ? $0 : nil }
                    ?? referenceActiveCalories
                calories = dynamicallyAdjustedCalories(
                    baseGoalCalories: base.calories,
                    dailyActiveCalories: activityCalories,
                    referenceActiveCalories: referenceActiveCalories
                )
            }
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
        let desiredProteinG = max(weightLbs, 0) * proteinGramsPerPound(for: goal)
        let fatCal = max(calories, 0) * fatCalorieFraction
        let minimumCarbCal = min(50 * 4, max(calories - fatCal, 0))
        let availableProteinCal = max(calories - fatCal - minimumCarbCal, 0)
        let proteinG = min(desiredProteinG, availableProteinCal / 4)
        let proteinCal = proteinG * 4
        let fatG = fatCal / 9
        let carbCal = max(calories - proteinCal - fatCal, 0)
        let carbG = carbCal / 4

        return (protein: proteinG, carbs: carbG, fat: fatG)
    }

    static func proteinGramsPerPound(for goal: WeightGoal) -> Double {
        switch goal {
        case .loseWeight: 0.85
        case .maintain: 0.75
        case .gainMuscle: 1.0
        }
    }

    static func suggestFiber(calories: Double) -> Double {
        max(calories, 0) * 14 / 1_000
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
