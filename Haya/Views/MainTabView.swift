import SwiftUI
import LocalAuthentication

/// Main app shell with custom bottom tab bar and auth toggle.
struct MainTabView: View {
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = 0
    @State private var showHidden = false
    @State private var isPerformingBiometrics = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab content with snappy crossfade
            NavigationStack {
                Group {
                    switch selectedTab {
                    case 0:
                        PhotoGridView(showHidden: $showHidden)
                    case 1:
                        PeopleView()
                    case 2:
                        ActivityView()
                    case 3:
                        SettingsView()
                    default:
                        PhotoGridView(showHidden: $showHidden)
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Custom bottom nav
            HayaTabBar(selectedTab: $selectedTab)
        }
        .sageBackground()
        .overlay(alignment: .topTrailing) {
            // Auth toggle button
            Button {
                toggleVisibility()
            } label: {
                Image(systemName: showHidden ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(showHidden ? Haya.Colors.accentOrange : Haya.Colors.textSageDim)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle().fill(Haya.Colors.glassBgWarm)
                            )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.18),
                                        Color.white.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Haya.Shadows.cardDrop, radius: 1, x: 1, y: 2)
                    .shadow(color: Haya.Shadows.soft, radius: 4, y: 2)
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && !isPerformingBiometrics {
                showHidden = false
            }
        }
    }

    private func toggleVisibility() {
        if showHidden {
            showHidden = false
        } else {
            authenticate()
        }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return
        }

        isPerformingBiometrics = true
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Reveal hidden photos"
        ) { success, _ in
            Task { @MainActor in
                isPerformingBiometrics = false
                if success { showHidden = true }
            }
        }
    }
}
