import SwiftUI

/// Full settings screen with people management, filter config, processing, and debug.
struct SettingsView: View {
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var appState: AppState

    @State private var enrollments: [PersonEnrollment] = []
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: Haya.Spacing.md) {
                // Header
                VStack(alignment: .leading, spacing: Haya.Spacing.xs) {
                    Text("Settings")
                        .font(HayaFont.largeTitle)
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("Configure Haya to your needs")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Haya.Spacing.lg)
                .padding(.top, Haya.Spacing.md)

                // Safe mode / crash diagnostic banner
                if CrashGuard.shared.isSafeMode || CrashGuard.shared.consecutiveCrashes > 0 {
                    crashDiagnosticSection
                        .padding(.horizontal, Haya.Spacing.lg)
                }

                // Processing
                processingSection
                    .padding(.horizontal, Haya.Spacing.lg)

                // VLM Model
                vlmModelSection
                    .padding(.horizontal, Haya.Spacing.lg)

                // Debug
                debugSection
                    .padding(.horizontal, Haya.Spacing.lg)

                // About
                aboutSection
                    .padding(.horizontal, Haya.Spacing.lg)

                // Danger zone
                dangerZone
                    .padding(.horizontal, Haya.Spacing.lg)

                Spacer().frame(height: Haya.Spacing.tabClearance)
            }
        }
        .task {
            enrollments = await pipeline.identifier.currentEnrollments
        }
        .alert("Reset All Data?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    for enrollment in enrollments {
                        do {
                            try await pipeline.identifier.removeEnrollment(id: enrollment.id)
                        } catch {
                            LogStore.shared.log(.error, "Settings", "Failed to remove enrollment \(enrollment.name): \(error.localizedDescription)")
                        }
                    }
                    enrollments = []
                    appState.hasCompletedOnboarding = false
                }
            }
        } message: {
            Text("This will remove all enrolled people and scan results. This cannot be undone.")
        }
    }

    private var vlmStatusText: String {
        switch pipeline.vlmService.downloadState {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .ready: return "Ready"
        case .error: return "Error"
        }
    }

    // MARK: - Processing

    private var processingSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Processing")

            // Batch size
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Batch Size")
                        .font(HayaFont.bodyText)
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("Photos processed per batch")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)
                }
                Spacer()
                Picker("", selection: $appState.batchSize) {
                    Text("10").tag(10)
                    Text("20").tag(20)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
                .tint(Haya.Colors.accentOrange)
            }

            // Scan on launch toggle
            Toggle(isOn: $appState.scanOnLaunch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan on Launch")
                        .font(HayaFont.bodyText)
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("Automatically scan new photos when app opens")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)
                }
            }
            .tint(Haya.Colors.accentOrange)

            // Rescan button
            Button {
                pipeline.rescanAll(batchSize: appState.batchSize)
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Rescan All Photos")
                }
                .font(HayaFont.pill)
                .foregroundStyle(Haya.Colors.accentOrange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                        .strokeBorder(Haya.Colors.accentOrange.opacity(0.3), lineWidth: 1.5)
                )
            }
        }
        .glassCard()
    }

    // MARK: - VLM Model

    private var vlmModelSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "AI Model")

            switch pipeline.vlmService.downloadState {
            case .notDownloaded:
                // Model info + download button
                VStack(alignment: .leading, spacing: Haya.Spacing.sm) {
                    HStack(spacing: Haya.Spacing.md) {
                        Image(systemName: "brain")
                            .font(.system(size: 20))
                            .foregroundStyle(Haya.Colors.accentOrange)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: Haya.Radius.sm)
                                    .fill(Haya.Colors.accentOrange.opacity(0.12))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(pipeline.vlmService.currentModelID.components(separatedBy: "/").last ?? "VLM")
                                .font(HayaFont.headline)
                                .foregroundStyle(Haya.Colors.textCream)
                            Text("Required for automatic photo filtering")
                                .font(HayaFont.caption)
                                .foregroundStyle(Haya.Colors.textSageDim)
                        }
                    }

                    HStack(spacing: Haya.Spacing.lg) {
                        Label(VLMService.formattedModelSize, systemImage: "arrow.down.circle")
                            .font(HayaFont.caption)
                            .foregroundStyle(Haya.Colors.textSage)
                        Label(VLMService.availableDiskSpace + " free", systemImage: "internaldrive")
                            .font(HayaFont.caption)
                            .foregroundStyle(Haya.Colors.textSageDim)
                    }

                    Button {
                        Task { await pipeline.vlmService.downloadAndLoad() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download Model")
                        }
                        .font(HayaFont.pill)
                        .foregroundStyle(Haya.Colors.fgOnOrange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(Haya.Gradients.orangeCTA)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                        )
                        .compositingGroup()
                        .hayaShadowSm()
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: Haya.Spacing.xs) {
                        Image(systemName: "wifi")
                            .font(.system(size: 10))
                        Text("Wi-Fi recommended")
                            .font(HayaFont.caption2)
                    }
                    .foregroundStyle(Haya.Colors.textSageDim)
                }

            case .downloading(let progress):
                // Progress UI
                VStack(alignment: .leading, spacing: Haya.Spacing.sm) {
                    HStack {
                        Text("Downloading model...")
                            .font(HayaFont.headline)
                            .foregroundStyle(Haya.Colors.textCream)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(HayaFont.caption)
                            .foregroundStyle(Haya.Colors.accentOrange)
                            .monospacedDigit()
                    }

                    ProgressView(value: progress)
                        .tint(Haya.Colors.accentOrange)

                    let downloadedBytes = Int64(progress * Double(VLMService.estimatedModelSizeBytes))
                    Text("\(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) / \(VLMService.formattedModelSize)")
                        .font(HayaFont.caption2)
                        .foregroundStyle(Haya.Colors.textSageDim)
                        .monospacedDigit()
                }

            case .ready:
                // Model loaded
                HStack(spacing: Haya.Spacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Haya.Colors.accentGreen)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Ready")
                            .font(HayaFont.headline)
                            .foregroundStyle(Haya.Colors.textCream)
                        Text(pipeline.vlmService.currentModelID.components(separatedBy: "/").last ?? "")
                            .font(HayaFont.caption)
                            .foregroundStyle(Haya.Colors.textSageDim)
                    }

                    Spacer()

                    Button {
                        pipeline.releaseVLM()
                    } label: {
                        Text("Unload")
                            .font(HayaFont.caption)
                            .foregroundStyle(Haya.Colors.textSageDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

            case .error(let message):
                // Error state with retry
                VStack(alignment: .leading, spacing: Haya.Spacing.sm) {
                    HStack(spacing: Haya.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Haya.Colors.accentRose)
                        Text("Download Failed")
                            .font(HayaFont.headline)
                            .foregroundStyle(Haya.Colors.textCream)
                    }

                    Text(message)
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)
                        .lineLimit(3)

                    Button {
                        Task { await pipeline.vlmService.downloadAndLoad() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(HayaFont.pill)
                        .foregroundStyle(Haya.Colors.accentOrange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: Haya.Radius.sm)
                                .strokeBorder(Haya.Colors.accentOrange.opacity(0.3), lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .glassCard()
    }

    // MARK: - Crash Diagnostic

    private var crashDiagnosticSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            HStack(spacing: Haya.Spacing.sm) {
                Image(systemName: CrashGuard.shared.isSafeMode ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Haya.Colors.accentRose)
                Text(CrashGuard.shared.isSafeMode ? "Safe Mode Active" : "Crash Detected")
                    .font(HayaFont.headline)
                    .foregroundStyle(Haya.Colors.textCream)
            }

            Text("The app crashed \(CrashGuard.shared.consecutiveCrashes) time(s) during scanning. Auto-scan is disabled to prevent crash loops. Current memory: \(CrashGuard.shared.logMemory("settings")) MB")
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSage)

            // Show last crash breadcrumbs
            let crumbs = CrashGuard.shared.lastCrashBreadcrumbs
            if !crumbs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last crash trace:")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(crumbs.suffix(15).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Haya.Colors.accentRose.opacity(0.8))
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: Haya.Radius.xs)
                            .fill(Color.black.opacity(0.3))
                    )
                }
            }

            HStack(spacing: Haya.Spacing.md) {
                if CrashGuard.shared.isSafeMode {
                    Button {
                        CrashGuard.shared.exitSafeMode()
                        pipeline.startBackgroundScan(batchSize: appState.batchSize)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Exit Safe Mode & Retry Scan")
                        }
                        .font(HayaFont.pill)
                        .foregroundStyle(Haya.Colors.accentOrange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: Haya.Radius.sm)
                                .strokeBorder(Haya.Colors.accentOrange.opacity(0.3), lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    UIPasteboard.general.string = CrashGuard.shared.diagnosticSummary()
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Diagnostics")
                    }
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textSage)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Haya.Radius.sm)
                            .strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard()
    }

    // MARK: - Debug

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Debug")

            VStack(spacing: Haya.Spacing.sm) {
                let ios = ProcessInfo.processInfo.operatingSystemVersion
                debugRow("iOS", value: "\(ios.majorVersion).\(ios.minorVersion).\(ios.patchVersion)")
                debugRow("Detection", value: ios.majorVersion >= 26 ? "Face + Direct YOLO (iOS 26)" : "Full (Vision)")
                debugRow("Pipeline", value: pipeline.loadingStatus)
                debugRow("VLM Status", value: vlmStatusText)
                debugRow("People Enrolled", value: "\(enrollments.count)")
                debugRow("Photos Scanned", value: "\(pipeline.scanProgress.processed)/\(pipeline.scanProgress.total)")
                debugRow("Hidden", value: "\(pipeline.scanProgress.hidden)")
                debugRow("Memory", value: "\(CrashGuard.availableMemoryMB) MB free")
                debugRow("Disk Free", value: VLMService.availableDiskSpace)
                debugRow("Crash Count", value: "\(CrashGuard.shared.consecutiveCrashes)")
            }

            // Always-on "Copy Diagnostics" button
            Button {
                UIPasteboard.general.string = CrashGuard.shared.diagnosticSummary()
                    + "\n\n--- Current breadcrumbs ---\n"
                    + CrashGuard.shared.currentBreadcrumbs.joined(separator: "\n")
            } label: {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy Full Diagnostics")
                }
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                        .strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .glassCard()
    }

    private func debugRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSage)
            Spacer()
            Text(value)
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textCream)
                .lineLimit(1)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "About")

            VStack(spacing: Haya.Spacing.sm) {
                debugRow("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                debugRow("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
            }

            HStack(spacing: Haya.Spacing.sm) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Haya.Colors.accentGreen)
                Text("All photo processing happens entirely on your device. Your photos never leave your phone.")
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textSage)
            }
        }
        .glassCard()
    }

    // MARK: - Danger Zone

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Data")

            Button {
                showResetConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Reset All Data")
                }
                .font(HayaFont.pill)
                .foregroundStyle(Haya.Colors.statusHide)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                        .strokeBorder(Haya.Colors.statusHide.opacity(0.3), lineWidth: 1.5)
                )
            }
        }
        .glassCard()
    }
}
