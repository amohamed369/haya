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

                // Filter Defaults
                filterDefaultsSection
                    .padding(.horizontal, Haya.Spacing.lg)

                // Processing
                processingSection
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

                Spacer().frame(height: 120)
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
                        try? await pipeline.identifier.removeEnrollment(id: enrollment.id)
                    }
                    enrollments = []
                    appState.hasCompletedOnboarding = false
                }
            }
        } message: {
            Text("This will remove all enrolled people and scan results. This cannot be undone.")
        }
    }

    // MARK: - Filter Defaults

    private var filterDefaultsSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Filter Defaults")

            // Default prompt editor
            VStack(alignment: .leading, spacing: Haya.Spacing.sm) {
                Text("Default Filter Prompt")
                    .font(HayaFont.label)
                    .foregroundStyle(Haya.Colors.textSage)
                    .textCase(.uppercase)
                    .tracking(0.5)

                TextEditor(text: $appState.defaultFilterPrompt)
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textCream)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(Haya.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Haya.Radius.sm)
                            .fill(Haya.Colors.glassBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Haya.Radius.sm)
                            .strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                    )
            }

            // Sensitivity slider
            VStack(alignment: .leading, spacing: Haya.Spacing.sm) {
                HStack {
                    Text("Sensitivity")
                        .font(HayaFont.label)
                        .foregroundStyle(Haya.Colors.textSage)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Text(sensitivityLabel)
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.accentOrange)
                }

                Slider(value: $appState.globalSensitivity, in: 0...1, step: 0.1)
                    .tint(Haya.Colors.accentOrange)

                HStack {
                    Text("Lenient")
                        .font(HayaFont.caption2)
                        .foregroundStyle(Haya.Colors.textSageDim)
                    Spacer()
                    Text("Strict")
                        .font(HayaFont.caption2)
                        .foregroundStyle(Haya.Colors.textSageDim)
                }
            }
        }
        .glassCard()
    }

    private var sensitivityLabel: String {
        switch appState.globalSensitivity {
        case 0..<0.3: return "Lenient"
        case 0.3..<0.7: return "Balanced"
        default: return "Strict"
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
                // TODO: Trigger full rescan
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

    // MARK: - Debug

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Debug")

            VStack(spacing: Haya.Spacing.sm) {
                debugRow("Pipeline", value: pipeline.loadingStatus)
                debugRow("VLM Model", value: pipeline.vlmService.currentModelID.components(separatedBy: "/").last ?? "—")
                debugRow("VLM Loaded", value: pipeline.vlmService.isLoaded ? "Yes" : "No")
                debugRow("People Enrolled", value: "\(enrollments.count)")
                debugRow("Photos Scanned", value: "0") // TODO: from ScanEngine
            }
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
