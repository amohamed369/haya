import SwiftUI
import Photos
import PhotosUI
import CoreImage

struct PhotoDetailView: View {
    @EnvironmentObject var pipeline: Pipeline
    var asset: PHAsset?
    var testMode: Bool = false

    @State private var image: UIImage?
    @State private var filterResult: PhotoFilterResult?
    @State private var isProcessing = false
    @State private var selectedItem: PhotosPickerItem?
    @State private var testImage: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: Haya.Spacing.md) {
                // Photo display
                photoCard
                    .padding(.horizontal, Haya.Spacing.lg)

                // Test mode photo picker
                if testMode {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo.badge.plus")
                            Text("Select Photo")
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
                    .padding(.horizontal, Haya.Spacing.lg)
                    .onChange(of: selectedItem) { _, newValue in
                        Task { await loadSelectedItem(newValue) }
                    }
                }

                // Run pipeline button
                if displayImage != nil {
                    Button {
                        Task { await runPipeline() }
                    } label: {
                        HStack {
                            if isProcessing {
                                ProgressView()
                                    .tint(Haya.Colors.fgOnOrange)
                                    .scaleEffect(0.8)
                                Text("Processing...")
                            } else {
                                Image(systemName: "play.circle.fill")
                                Text("Run Pipeline")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.hayaPill)
                    .disabled(isProcessing || !pipeline.isReady)
                    .padding(.horizontal, Haya.Spacing.lg)
                }

                // Results
                if let result = filterResult {
                    ResultsView(result: result)
                        .padding(.horizontal, Haya.Spacing.lg)
                }

                Spacer().frame(height: Haya.Spacing.tabClearance)
            }
            .padding(.top, Haya.Spacing.md)
        }
        .sageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let asset = asset {
                await loadFullImage(asset)
            }
        }
    }

    // MARK: - Photo Card

    private var photoCard: some View {
        ZStack {
            if let img = displayImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Haya.Radius.md))
                    .overlay {
                        if let result = filterResult {
                            DetectionOverlay(result: result, imageSize: img.size)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: Haya.Radius.md)
                    .fill(Haya.Colors.glassBg)
                    .aspectRatio(3/4, contentMode: .fit)
                    .overlay {
                        if isProcessing {
                            VStack(spacing: Haya.Spacing.sm) {
                                ProgressView()
                                    .tint(Haya.Colors.accentOrange)
                                Text("Loading...")
                                    .font(HayaFont.caption)
                                    .foregroundStyle(Haya.Colors.textSageDim)
                            }
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(Haya.Colors.textSageDim)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Haya.Radius.md)
                            .strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                    )
            }
        }
        .hayaShadowLg()
    }

    private var displayImage: UIImage? {
        testImage ?? image
    }

    // MARK: - Image Loading

    private func loadFullImage(_ asset: PHAsset) async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let targetSize = CGSize(width: 1200, height: 1200)

        image = await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize,
                contentMode: .aspectFit, options: options
            ) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: img)
            }
        }
    }

    private func loadSelectedItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let uiImage = UIImage(data: data) {
            testImage = uiImage
            filterResult = nil
        }
    }

    private func runPipeline() async {
        guard let uiImage = displayImage,
              let cgImage = uiImage.cgImage else { return }
        isProcessing = true
        defer { isProcessing = false }

        let ciImage = CIImage(cgImage: cgImage)
        filterResult = await pipeline.processPhoto(ciImage, asset: asset)
    }
}

// MARK: - Detection Overlay

struct DetectionOverlay: View {
    let result: PhotoFilterResult
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            ForEach(result.personResults) { person in
                let rect = scaledRect(person.person.boundingBox, in: geo.size)
                Rectangle()
                    .strokeBorder(borderColor(for: person), lineWidth: 2.5)
                    .background(
                        Rectangle().fill(borderColor(for: person).opacity(0.08))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Haya.Radius.xs))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .overlay(alignment: .topLeading) {
                        Text(labelText(for: person))
                            .font(HayaFont.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(borderColor(for: person).opacity(0.85))
                            )
                            .foregroundStyle(.white)
                            .position(x: rect.minX + 50, y: rect.minY - 10)
                    }
            }
        }
    }

    private func scaledRect(_ normalized: CGRect, in viewSize: CGSize) -> CGRect {
        CGRect(
            x: normalized.origin.x * viewSize.width,
            y: normalized.origin.y * viewSize.height,
            width: normalized.width * viewSize.width,
            height: normalized.height * viewSize.height
        )
    }

    private func borderColor(for result: PersonFilterResult) -> Color {
        result.decision.color
    }

    private func labelText(for result: PersonFilterResult) -> String {
        var parts: [String] = []
        if let name = result.identification?.name {
            parts.append(name)
        }
        switch result.person.source {
        case .faceOnly: parts.append("face")
        case .bodyOnly: parts.append("body")
        case .faceAndBody: parts.append("face+body")
        }
        parts.append(String(format: "%.0f%%", result.person.confidence * 100))
        return parts.joined(separator: " | ")
    }
}
