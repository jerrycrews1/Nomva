import Darwin
import Foundation

final class DailyGoal {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var createdAt = Date.now
    var isActive = true

    init(calories: Double, protein: Double, carbs: Double, fat: Double, fiber: Double = 25) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
    }
}

enum BiologicalSex {
    case male
    case female
    case notSpecified
}

enum ActivityLevel {
    case sedentary
    case lightlyActive
    case moderatelyActive
    case veryActive
    case extraActive

    var multiplier: Double {
        switch self {
        case .sedentary: 1.2
        case .lightlyActive: 1.375
        case .moderatelyActive: 1.55
        case .veryActive: 1.725
        case .extraActive: 1.9
        }
    }
}

enum GoalActivitySource {
    case manual
    case appleHealth
    case garmin
}

struct GoalActivityProfile {
    var source: GoalActivitySource
    var manualLevel: ActivityLevel?
    var averageActiveCalories: Double?

    static func manual(_ level: ActivityLevel) -> Self {
        Self(source: .manual, manualLevel: level, averageActiveCalories: nil)
    }

    static func measured(_ calories: Double, source: GoalActivitySource) -> Self {
        Self(source: source, manualLevel: nil, averageActiveCalories: calories)
    }
}

enum WeightGoal {
    case loseWeight
    case maintain
    case gainMuscle

    var displayName: String {
        switch self {
        case .loseWeight: "Lose Weight"
        case .maintain: "Maintain"
        case .gainMuscle: "Build Muscle"
        }
    }
}

@main
struct GoalServiceTests {
    private static var passed = 0
    private static var failed = 0

    static func main() {
        testRestingEstimate()
        testActivitySources()
        testGoalAdjustments()
        testMacroAllocation()
        testDynamicDailyAdjustment()
        testSameDayActivityCredit()

        print("Goal service tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func testRestingEstimate() {
        let male = GoalService.calculateBMR(
            weightLbs: 180,
            heightTotalInches: 70,
            ageYears: 35,
            sex: .male
        )
        let female = GoalService.calculateBMR(
            weightLbs: 180,
            heightTotalInches: 70,
            ageYears: 35,
            sex: .female
        )
        let unspecified = GoalService.calculateBMR(
            weightLbs: 180,
            heightTotalInches: 70,
            ageYears: 35,
            sex: .notSpecified
        )

        checkClose(male, 1_757.7156, tolerance: 0.001, "Mifflin-St Jeor male estimate")
        checkClose(female, 1_591.7156, tolerance: 0.001, "Mifflin-St Jeor female estimate")
        checkClose(unspecified, (male + female) / 2, tolerance: 0.001, "Unspecified sex uses the documented midpoint")
    }

    private static func testActivitySources() {
        let resting = GoalService.calculateBMR(
            weightLbs: 180,
            heightTotalInches: 70,
            ageYears: 35,
            sex: .male
        )
        let garminMaintenance = GoalService.calculateMaintenanceCalories(
            weightLbs: 180,
            heightTotalInches: 70,
            ageYears: 35,
            sex: .male,
            activityProfile: .measured(317, source: .garmin)
        )
        let appleMaintenance = GoalService.calculateMaintenanceCalories(
            weightLbs: 180,
            heightTotalInches: 70,
            ageYears: 35,
            sex: .male,
            activityProfile: .measured(317, source: .appleHealth)
        )
        let sedentaryMaintenance = GoalService.calculateMaintenanceCalories(
            weightLbs: 180,
            heightTotalInches: 70,
            ageYears: 35,
            sex: .male,
            activityProfile: .manual(.sedentary)
        )

        checkClose(garminMaintenance, resting + 317, tolerance: 0.001, "Garmin adds measured active calories to resting estimate")
        checkClose(appleMaintenance, resting + 317, tolerance: 0.001, "Apple Health uses the same measured-activity basis")
        checkClose(sedentaryMaintenance, resting * 1.2, tolerance: 0.001, "Manual activity uses the selected activity factor")
    }

    private static func testGoalAdjustments() {
        let inputs: [(WeightGoal, Double)] = [
            (.loseWeight, -500),
            (.maintain, 0),
            (.gainMuscle, 300),
        ]

        for (goal, adjustment) in inputs {
            let projection = GoalService.calculateProjection(
                weightLbs: 180,
                heightInches: 70,
                age: 35,
                sex: .male,
                activityProfile: .measured(317, source: .garmin),
                goal: goal
            )
            checkClose(
                projection.requestedAdjustmentCalories,
                adjustment,
                tolerance: 0.001,
                "\(goal.displayName) exposes its requested adjustment"
            )
            checkClose(
                projection.targetCalories,
                max((projection.maintenanceCalories + adjustment).rounded(), 1_000),
                tolerance: 0.001,
                "\(goal.displayName) target follows maintenance plus adjustment"
            )
        }

        let floorProjection = GoalService.calculateProjection(
            weightLbs: 75,
            heightInches: 48,
            age: 90,
            sex: .female,
            activityProfile: .measured(0, source: .appleHealth),
            goal: .loseWeight
        )
        check(floorProjection.targetCalories == 1_000, "Calorie safety floor is applied")
        check(floorProjection.minimumCaloriesApplied, "Projection reports when the floor changed the adjustment")
        checkClose(
            floorProjection.appliedAdjustmentCalories,
            floorProjection.targetCalories - floorProjection.maintenanceCalories,
            tolerance: 0.001,
            "Applied adjustment reflects the clamped target"
        )
    }

    private static func testMacroAllocation() {
        let expectedProtein: [(WeightGoal, Double)] = [
            (.loseWeight, 0.85),
            (.maintain, 0.75),
            (.gainMuscle, 1.0),
        ]

        for (goal, gramsPerPound) in expectedProtein {
            let projection = GoalService.calculateProjection(
                weightLbs: 180,
                heightInches: 70,
                age: 35,
                sex: .male,
                activityProfile: .measured(400, source: .garmin),
                goal: goal
            )
            let macroCalories = projection.protein * 4 + projection.carbs * 4 + projection.fat * 9

            checkClose(projection.proteinGramsPerPound, gramsPerPound, tolerance: 0.001, "\(goal.displayName) protein basis")
            checkClose(projection.protein, 180 * gramsPerPound, tolerance: 0.001, "\(goal.displayName) protein target")
            checkClose(projection.fatCaloriePercentage, 28, tolerance: 0.001, "\(goal.displayName) fat percentage")
            checkClose(macroCalories, projection.targetCalories, tolerance: 0.001, "\(goal.displayName) macros reconcile to calories")
            checkClose(projection.fiber, projection.targetCalories * 14 / 1_000, tolerance: 0.001, "\(goal.displayName) fiber basis")
        }

        let constrained = GoalService.suggestMacros(
            calories: 1_000,
            weightLbs: 600,
            goal: .gainMuscle
        )
        let constrainedCalories = constrained.protein * 4 + constrained.carbs * 4 + constrained.fat * 9
        checkClose(constrainedCalories, 1_000, tolerance: 0.001, "Constrained macros cannot exceed calorie target")
        check(constrained.carbs >= 50, "Constrained macros preserve the carbohydrate floor")
    }

    private static func testDynamicDailyAdjustment() {
        checkClose(
            GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: 2_000,
                dailyActiveCalories: 500,
                referenceActiveCalories: 300
            ),
            2_200,
            tolerance: 0.001,
            "Above-baseline activity increases the displayed goal"
        )
        checkClose(
            GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: 2_000,
                dailyActiveCalories: 200,
                referenceActiveCalories: 300
            ),
            1_900,
            tolerance: 0.001,
            "Below-baseline activity decreases the displayed goal"
        )
        checkClose(
            GoalService.dynamicallyAdjustedCalories(
                baseGoalCalories: 2_000,
                dailyActiveCalories: 800,
                referenceActiveCalories: 0
            ),
            2_000,
            tolerance: 0.001,
            "Missing activity reference leaves the base goal unchanged"
        )
    }

    private static func testSameDayActivityCredit() {
        checkClose(
            GoalService.sameDayAdjustedCalories(
                baseGoalCalories: 2_000,
                currentDayActiveCalories: 100,
                rollingAverageActiveCalories: 300,
                referenceActiveCalories: 300
            ),
            2_000,
            tolerance: 0.001,
            "A partial current day cannot lower the calorie goal"
        )
        checkClose(
            GoalService.sameDayAdjustedCalories(
                baseGoalCalories: 2_000,
                currentDayActiveCalories: 600,
                rollingAverageActiveCalories: 300,
                referenceActiveCalories: 300
            ),
            2_300,
            tolerance: 0.001,
            "Activity 300 kcal above today's baseline earns 300 kcal"
        )
        checkClose(
            GoalService.sameDayAdjustedCalories(
                baseGoalCalories: 2_000,
                currentDayActiveCalories: 350,
                rollingAverageActiveCalories: 400,
                referenceActiveCalories: 300
            ),
            2_100,
            tolerance: 0.001,
            "A changed rolling baseline remains reflected before live activity exceeds it"
        )
        checkClose(
            GoalService.sameDayAdjustedCalories(
                baseGoalCalories: 2_000,
                currentDayActiveCalories: 900,
                rollingAverageActiveCalories: 300,
                referenceActiveCalories: 0
            ),
            2_000,
            tolerance: 0.001,
            "Live activity cannot change a goal that has no measured reference"
        )

        let base = DailyGoal(calories: 2_000, protein: 150, carbs: 200, fat: 60)
        let today = GoalService.displayGoal(
            base: base,
            selectedDate: .now,
            activitySource: .garmin,
            referenceActiveCalories: 300,
            averageActiveCalories: 300,
            currentDayActiveCalories: 600,
            completedDayActiveCalories: nil
        )
        checkClose(today.calories, 2_300, tolerance: 0.001, "Today's display goal uses excess live Garmin activity")

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let completedDay = GoalService.displayGoal(
            base: base,
            selectedDate: yesterday,
            activitySource: .garmin,
            referenceActiveCalories: 300,
            averageActiveCalories: 300,
            currentDayActiveCalories: nil,
            completedDayActiveCalories: 200
        )
        checkClose(completedDay.calories, 1_900, tolerance: 0.001, "A completed day retains its full signed activity adjustment")
    }

    private static func checkClose(
        _ actual: Double,
        _ expected: Double,
        tolerance: Double,
        _ name: String
    ) {
        check(abs(actual - expected) <= tolerance, "\(name) (expected \(expected), got \(actual))")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            passed += 1
            print("PASS: \(name)")
        } else {
            failed += 1
            print("FAIL: \(name)")
        }
    }
}
