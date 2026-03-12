import SwiftUI

/// Displays full pipeline results with the design system.
struct ResultsView: View {
    let result: PhotoFilterResult

    var body: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            // Overall verdict
            overallBadge

            Text("\(result.personResults.count) person(s) detected")
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSageDim)

            // Per-person results
            ForEach(result.personResults) { person in
                PersonResultCard(result: person)
            }
        }
    }

    private var overallBadge: some View {
        HStack {
            Image(systemName: result.overallDecision.icon)
                .foregroundStyle(result.overallDecision.color)
            Text(result.overallDecision.displayText)
                .font(HayaFont.headline)
                .foregroundStyle(result.overallDecision.color)
            Spacer()
            Text("\(result.processingTimeMs)ms")
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSageDim)
        }
        .padding(.horizontal, Haya.Spacing.md)
        .padding(.vertical, Haya.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Haya.Radius.sm)
                .fill(result.overallDecision.color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Haya.Radius.sm)
                .strokeBorder(result.overallDecision.color.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Person Result Card

struct PersonResultCard: View {
    let result: PersonFilterResult

    var body: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.sm) {
            // Header
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(iconColor.opacity(0.12))
                    )

                Text(headerText)
                    .font(HayaFont.subheadline)
                    .foregroundStyle(Haya.Colors.textCream)

                Spacer()

                StatusBadge(text: result.decision.shortText, color: result.decision.color)
            }

            // Detection info
            HStack(spacing: Haya.Spacing.md) {
                Label(sourceText, systemImage: "viewfinder")
                Label(String(format: "%.0f%%", result.person.confidence * 100), systemImage: "sparkles")
            }
            .font(HayaFont.caption)
            .foregroundStyle(Haya.Colors.textSageDim)

            // Identification
            if let id = result.identification {
                if id.isMatch {
                    HStack(spacing: Haya.Spacing.md) {
                        if let faceSim = id.faceSimilarity {
                            Label(String(format: "Face: %.2f", faceSim), systemImage: "face.smiling")
                                .foregroundStyle(Haya.Colors.accentGreen)
                        }
                        if let bodySim = id.bodySimilarity {
                            Label(String(format: "Body: %.2f", bodySim), systemImage: "figure.stand")
                                .foregroundStyle(Haya.Colors.accentTeal)
                        }
                    }
                    .font(HayaFont.caption)
                } else {
                    Text("Not enrolled")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.accentYellow)
                }
            }

            // Hair seg result
            if let hair = result.hairSegResult {
                HStack {
                    Image(systemName: "scissors")
                    Text(String(format: "Hair ratio: %.2f", hair.hairRatio))
                    if hair.skipVLM {
                        Text("(VLM skipped)")
                            .foregroundStyle(Haya.Colors.accentYellow)
                    }
                }
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSageDim)
            }

            // VLM assessment
            if let vlm = result.modestyAssessment {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "brain")
                        Text("VLM: \(vlm.isModest ? "Modest" : "Not Modest")")
                            .foregroundStyle(vlm.isModest ? Haya.Colors.accentGreen : Haya.Colors.statusHide)
                        Text("(\(vlm.confidence.rawValue))")
                            .foregroundStyle(Haya.Colors.textSageDim)
                    }
                    .font(HayaFont.caption)

                    Text(vlm.reason)
                        .font(HayaFont.caption2)
                        .foregroundStyle(Haya.Colors.textSageDim)
                        .lineLimit(3)
                }
            }

            // Decision reason
            Text(result.decisionReason)
                .font(HayaFont.caption2)
                .foregroundStyle(Haya.Colors.textSageDim.opacity(0.7))
        }
        .glassCard(padding: 16, radius: Haya.Radius.md)
    }

    private var iconName: String {
        switch result.person.source {
        case .faceOnly: return "face.smiling"
        case .bodyOnly: return "figure.stand"
        case .faceAndBody: return "person.crop.rectangle"
        }
    }

    private var iconColor: Color {
        switch result.person.source {
        case .faceOnly: return Haya.Colors.accentGreen
        case .bodyOnly: return Haya.Colors.accentTeal
        case .faceAndBody: return Haya.Colors.accentLavender
        }
    }

    private var headerText: String {
        result.identification?.name ?? "Unknown Person"
    }

    private var sourceText: String {
        switch result.person.source {
        case .faceOnly: return "Face"
        case .bodyOnly: return "Body"
        case .faceAndBody: return "Face + Body"
        }
    }

}
