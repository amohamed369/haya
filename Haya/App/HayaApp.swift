import SwiftUI

@main
struct HayaApp: App {
    @StateObject private var pipeline = Pipeline()
    @StateObject private var appState = AppState()

    /// True if CrashGuard detected a crash loop on launch.
    @State private var safeModeActive = false

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
                // Check for crash loop FIRST
                let isSafe = CrashGuard.shared.checkOnLaunch()
                safeModeActive = isSafe

                let ios = ProcessInfo.processInfo.operatingSystemVersion
                CrashGuard.shared.breadcrumb("App", "Launch iOS \(ios.majorVersion).\(ios.minorVersion).\(ios.patchVersion)")

                if isSafe {
                    LogStore.shared.log(.warning, "App", "Safe mode — scan disabled after \(CrashGuard.shared.consecutiveCrashes) crash(es)")
                    // Log last crash breadcrumbs into LogStore so user can see them
                    let crumbs = CrashGuard.shared.lastCrashBreadcrumbs
                    if !crumbs.isEmpty {
                        LogStore.shared.log(.error, "CrashLog", "Last crash breadcrumbs:")
                        for crumb in crumbs.suffix(15) {
                            LogStore.shared.log(.error, "CrashLog", crumb)
                        }
                    }
                }

                CrashGuard.shared.breadcrumb("App", "loadModels() START")
                await pipeline.loadModels()
                CrashGuard.shared.breadcrumb("App", "loadModels() DONE ready=\(pipeline.isReady)")

                // Auto-scan on launch if enabled, onboarding complete, and not in safe mode
                if appState.hasCompletedOnboarding && appState.scanOnLaunch && !isSafe {
                    pipeline.startBackgroundScan(batchSize: appState.batchSize)
                }
            }
            .onChange(of: appState.hasCompletedOnboarding) { _, completed in
                // Trigger first scan when onboarding finishes
                // Guard: only if not already scanning and not in safe mode
                if completed && pipeline.isReady && !pipeline.scanProgress.isScanning && !safeModeActive {
                    pipeline.startBackgroundScan(batchSize: appState.batchSize)
                }
            }
            .onAppear {
                HayaFont.logAvailableFonts()
            }
        }
    }
}
