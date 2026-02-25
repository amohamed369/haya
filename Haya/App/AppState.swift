import SwiftUI
import Photos

/// Central app state — manages onboarding, settings, and scan state.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Onboarding

    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    @AppStorage("hasRequestedPhotoAccess") var hasRequestedPhotoAccess = false

    // MARK: - Settings

    @AppStorage("scanOnLaunch") var scanOnLaunch = true
    @AppStorage("batchSize") var batchSize = 20
    @AppStorage("defaultFilterPrompt") var defaultFilterPrompt = """
    Evaluate this person for modesty. Default answer is NO.

    Check each — if ANY fails, answer NO:
    [ ] Hair mostly covered (hijab, scarf, beanie, hoodie)
    [ ] Arms covered to wrists
    [ ] Legs covered (long pants or skirt)
    [ ] Clothing loose, not tight

    If ANY check FAIL: answer NO
    Only if ALL checks pass: answer YES

    Format: YES or NO, confidence (high/medium/low), which check failed or "all pass"
    """
    @AppStorage("globalSensitivity") var globalSensitivity: Double = 0.5

    // MARK: - Photo Access

    var photoAuthorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestPhotoAccess() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        hasRequestedPhotoAccess = true
        return status
    }
}
