import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .chat
    @StateObject private var subManager = SubscriptionManager.shared

    enum Tab {
        case chat, log, weight, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Group {
                if subManager.canUseAI {
                    ChatView()
                } else {
                    PaywallView()
                }
            }
            .tabItem {
                Label("AI Chat", systemImage: "sparkles")
            }
            .tag(Tab.chat)

            DailyLogView()
                .tabItem {
                    Label("Log", systemImage: "list.bullet.clipboard")
                }
                .tag(Tab.log)

            WeightLoggingView()
                .tabItem {
                    Label("Weight", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(Tab.weight)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .tint(NomvaTheme.accent)
    }
}

#Preview {
    ContentView()
}
