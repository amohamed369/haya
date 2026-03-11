import SwiftUI

@main
struct HayaApp: App {
    @StateObject private var pipeline = Pipeline()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.hasCompletedOnboarding {
                    MainTabView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(pipeline)
            .environmentObject(appState)
            .preferredColorScheme(.dark)
            .task {
                await pipeline.loadModels()
            }
            .onAppear {
                HayaFont.logAvailableFonts()
            }
        }
    }
}
