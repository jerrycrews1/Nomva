import SwiftUI
import WidgetKit

@main
struct NomvaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodaySummaryWidget()
        HydrationWidget()
        ActivityGoalWidget()
        WeightTrendWidget()
        QuickLogLauncherWidget()
    }
}
