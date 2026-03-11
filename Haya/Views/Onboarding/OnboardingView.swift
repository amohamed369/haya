import SwiftUI
import Photos

/// Full-screen onboarding: welcome → photo access → person setup.
struct OnboardingView: View {
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var appState: AppState

    @State private var currentStep: OnboardingStep = .welcome
    @State private var animateIn = false

    enum OnboardingStep {
        case welcome
        case photoAccess
        case personSetup
    }

    var body: some View {
        ZStack {
            switch currentStep {
            case .welcome:
                welcomeStep
            case .photoAccess:
                photoAccessStep
            case .personSetup:
                PersonSetupView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        appState.hasCompletedOnboarding = true
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sageBackground()
        .onAppear {
            withAnimation(Haya.Motion.entrance.delay(0.15)) {
                animateIn = true
            }
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: Haya.Spacing.md) {
                // App icon placeholder
                ZStack {
                    Circle()
                        .fill(Haya.Gradients.avatarOrange)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
                        )
                        .hayaShadowMd()

                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Haya.Colors.fgOnOrangeSoft)
                }
                .scaleEffect(animateIn ? 1 : 0.6)
                .opacity(animateIn ? 1 : 0)

                Text("Haya")
                    .font(HayaFont.heading(42, weight: .bold))
                    .foregroundStyle(Haya.Colors.textCream)
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 20)

                Text("Your photos, your privacy")
                    .font(HayaFont.body(16, weight: .regular))
                    .foregroundStyle(Haya.Colors.textSage)
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 10)
            }

            Spacer()

            VStack(spacing: Haya.Spacing.md) {
                // Feature highlights
                featureRow(icon: "lock.shield.fill", text: "100% on-device processing")
                featureRow(icon: "person.crop.circle.badge.checkmark", text: "Per-person AI filtering")
                featureRow(icon: "photo.on.rectangle.angled", text: "Smart photo management")
            }
            .padding(.horizontal, Haya.Spacing.xl)
            .opacity(animateIn ? 1 : 0)

            Spacer()

            Button("Get Started") {
                withAnimation(Haya.Motion.standard) {
                    currentStep = .photoAccess
                }
            }
            .buttonStyle(.hayaPill)
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 30)

            Spacer().frame(height: Haya.Spacing.xxl)
        }
        .transition(.opacity)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: Haya.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Haya.Colors.accentOrange)
                .frame(width: 36)

            Text(text)
                .font(HayaFont.body(15, weight: .medium))
                .foregroundStyle(Haya.Colors.textCream)

            Spacer()
        }
        .padding(.vertical, Haya.Spacing.sm)
    }

    // MARK: - Photo Access

    private var photoAccessStep: some View {
        VStack(spacing: Haya.Spacing.xl) {
            Spacer()

            VStack(spacing: Haya.Spacing.md) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Haya.Colors.accentOrange)

                Text("Access Your Photos")
                    .font(HayaFont.title)
                    .foregroundStyle(Haya.Colors.textCream)

                Text("Haya needs access to your photo library to scan and protect your photos. Everything stays on your device.")
                    .font(HayaFont.bodyText)
                    .foregroundStyle(Haya.Colors.textSage)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Haya.Spacing.xl)
            }

            Spacer()

            VStack(spacing: Haya.Spacing.md) {
                Button("Allow Photo Access") {
                    Task {
                        let status = await appState.requestPhotoAccess()
                        if status == .authorized || status == .limited {
                            withAnimation(Haya.Motion.standard) {
                                currentStep = .personSetup
                            }
                        }
                    }
                }
                .buttonStyle(.hayaPill)

                if appState.photoAuthorizationStatus == .denied {
                    Text("Photo access was denied. Open Settings to enable it.")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.accentRose)
                        .multilineTextAlignment(.center)

                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.hayaPillSecondary)
                }
            }

            Spacer().frame(height: Haya.Spacing.xxl)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
