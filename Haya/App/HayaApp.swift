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
            .environmentObject(LogStore.shared)
            .preferredColorScheme(.dark)
            .task {
                await pipeline.loadModels()
                // Auto-scan on launch if enabled and onboarding complete
                if appState.hasCompletedOnboarding && appState.scanOnLaunch {
                    pipeline.startBackgroundScan(batchSize: appState.batchSize)
                }
            }
            .onChange(of: appState.hasCompletedOnboarding) { _, completed in
                // Trigger first scan when onboarding finishes
                if completed && pipeline.isReady {
                    pipeline.startBackgroundScan(batchSize: appState.batchSize)
                }
            }
            .onAppear {
                HayaFont.logAvailableFonts()
            }
        }
    }
}
