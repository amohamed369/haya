import SwiftUI

/// Activity tab: scan progress, model status, processing stats.
struct ActivityView: View {
    @EnvironmentObject var pipeline: Pipeline

    @State private var animateArc = false

    var body: some View {
        ScrollView {
            VStack(spacing: Haya.Spacing.md) {
                // Header
                VStack(alignment: .leading, spacing: Haya.Spacing.xs) {
                    Text("Activity")
                        .font(HayaFont.largeTitle)
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("Processing status & insights")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Haya.Spacing.lg)
                .padding(.top, Haya.Spacing.md)

                // Scan Progress Arc Card
                scanProgressCard
                    .padding(.horizontal, Haya.Spacing.lg)

                // Model Status Card
                modelStatusCard
                    .padding(.horizontal, Haya.Spacing.lg)

                // Pipeline Stages
                pipelineStagesCard
                    .padding(.horizontal, Haya.Spacing.lg)

                // Test section
                testSection
                    .padding(.horizontal, Haya.Spacing.lg)

                Spacer().frame(height: 100)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).delay(0.3)) {
                animateArc = true
            }
        }
    }

    // MARK: - Scan Progress

    private var scanProgressCard: some View {
        VStack(spacing: Haya.Spacing.md) {
            HStack {
                Text("Scan Progress")
                    .font(HayaFont.title3)
                    .foregroundStyle(Haya.Colors.textCream)
                Spacer()
                StatusBadge(
                    text: pipeline.isReady ? "Ready" : "Loading",
                    color: pipeline.isReady ? Haya.Colors.accentGreen : Haya.Colors.accentYellow
                )
            }

            // Arc visualization
            ZStack {
                // Track
                ArcShape()
                    .stroke(
                        Haya.Colors.glassBg,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .frame(width: 180, height: 100)

                // Fill
                ArcShape()
                    .trim(from: 0, to: animateArc ? 0.0 : 0.0) // 0% — no photos scanned yet
                    .stroke(
                        Haya.Gradients.orangeCTA,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .frame(width: 180, height: 100)

                // Center text
                VStack(spacing: 2) {
                    Text("0")
                        .font(HayaFont.heading(36, weight: .bold))
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("SCANNED")
                        .font(HayaFont.caption2)
                        .foregroundStyle(Haya.Colors.textSageDim)
                        .tracking(0.6)
                }
                .offset(y: 10)
            }
            .frame(height: 120)

            // Mini stats
            HStack(spacing: Haya.Spacing.sm) {
                miniStat(value: "0", label: "Hidden", icon: "eye.slash", color: Haya.Colors.accentOrange)
                miniStat(value: "0", label: "Kept", icon: "checkmark.circle", color: Haya.Colors.accentTeal)
                miniStat(value: "0", label: "Pending", icon: "clock", color: Haya.Colors.accentLavender)
            }
        }
        .glassCard()
    }

    private func miniStat(value: String, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(color.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(HayaFont.heading(15, weight: .semibold))
                    .foregroundStyle(Haya.Colors.textCream)
                Text(label)
                    .font(HayaFont.caption2)
                    .foregroundStyle(Haya.Colors.textSageDim)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Haya.Radius.md)
                .fill(Haya.Colors.glassBg)
                .overlay(
                    RoundedRectangle(cornerRadius: Haya.Radius.md)
                        .strokeBorder(Haya.Colors.glassBorder, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Model Status

    private var modelStatusCard: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            Text("Model Status")
                .font(HayaFont.title3)
                .foregroundStyle(Haya.Colors.textCream)

            VStack(spacing: Haya.Spacing.sm) {
                statusRow("Pipeline", value: pipeline.loadingStatus, ready: pipeline.isReady)
                statusRow(
                    "VLM",
                    value: pipeline.vlmService.currentModelID.components(separatedBy: "/").last ?? "",
                    ready: pipeline.vlmService.isLoaded
                )
            }

            if pipeline.vlmLoadingProgress > 0 && pipeline.vlmLoadingProgress < 1 {
                ProgressView(value: pipeline.vlmLoadingProgress)
                    .tint(Haya.Colors.accentOrange)
            }
        }
        .glassCard()
    }

    private func statusRow(_ label: String, value: String, ready: Bool) -> some View {
        HStack {
            Circle()
                .fill(ready ? Haya.Colors.accentGreen : Haya.Colors.accentYellow)
                .frame(width: 8, height: 8)
            Text(label)
                .font(HayaFont.bodyText)
                .foregroundStyle(Haya.Colors.textCream)
            Spacer()
            Text(value)
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSageDim)
                .lineLimit(1)
        }
    }

    // MARK: - Pipeline Stages

    private var pipelineStagesCard: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            Text("Pipeline Stages")
                .font(HayaFont.title3)
                .foregroundStyle(Haya.Colors.textCream)

            VStack(spacing: Haya.Spacing.sm) {
                stageRow(icon: "person.crop.rectangle", label: "Person Detection", detail: "Vision + YOLO11n", color: Haya.Colors.accentTeal)
                stageRow(icon: "person.crop.circle", label: "Person Identification", detail: "ArcFace + CLIP-ReID", color: Haya.Colors.accentLavender)
                stageRow(icon: "scissors", label: "Hair Segmentation", detail: "MediaPipe pre-filter", color: Haya.Colors.accentYellow)
                stageRow(icon: "brain", label: "Modesty Assessment", detail: "SmolVLM2", color: Haya.Colors.accentOrange)
            }
        }
        .glassCard()
    }

    private func stageRow(icon: String, label: String, detail: String, color: Color) -> some View {
        HStack(spacing: Haya.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(HayaFont.subheadline)
                    .foregroundStyle(Haya.Colors.textCream)
                Text(detail)
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textSageDim)
            }

            Spacer()
        }
    }

    // MARK: - Test Section

    private var testSection: some View {
        NavigationLink {
            PhotoDetailView(testMode: true)
                .environmentObject(pipeline)
        } label: {
            HStack(spacing: Haya.Spacing.md) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Haya.Colors.accentOrange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Test Pipeline")
                        .font(HayaFont.headline)
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("Run the full pipeline on a single photo")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Haya.Colors.textSageDim)
            }
            .glassCard(padding: 16, radius: Haya.Radius.lg)
        }
        .buttonStyle(.plain)
        .disabled(!pipeline.isReady)
    }
}

// MARK: - Arc Shape

struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let radius = min(rect.width / 2, rect.height) * 0.9
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
    }
}
