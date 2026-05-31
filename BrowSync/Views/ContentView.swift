// ContentView.swift
// BrowSync — Root TabView with 5 tabs

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .browsers

    var body: some View {
        TabView(selection: $selectedTab) {
            BrowsersView()
                .tabItem {
                    Label(String(localized: "Browsers"), systemImage: "globe")
                }
                .tag(AppTab.browsers)

            RulesView()
                .tabItem {
                    Label(String(localized: "Rules"), systemImage: "list.bullet.rectangle")
                }
                .tag(AppTab.rules)

            SyncView()
                .tabItem {
                    Label(String(localized: "Sync"), systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(AppTab.sync)

            GeneralView()
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }
                .tag(AppTab.general)

            AboutView()
                .tabItem {
                    Label(String(localized: "About"), systemImage: "info.circle")
                }
                .tag(AppTab.about)
        }
        .task {
            await appState.onAppear()
        }
    }
}

enum AppTab: Hashable {
    case browsers, rules, sync, general, about
}
