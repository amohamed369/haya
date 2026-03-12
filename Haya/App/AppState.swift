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
