import SwiftUI

@main
struct NoScrollApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(state)
                .onOpenURL { state.handle(url: $0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        TabView(selection: $state.tab) {
            HomeView().tag(AppState.Tab.home)
                .tabItem { Label("Home", systemImage: "house") }
            AllSettingsTab().tag(AppState.Tab.adjust)
                .tabItem { Label("Blocks", systemImage: "slider.horizontal.3") }
            ProfileTab().tag(AppState.Tab.profile)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}
