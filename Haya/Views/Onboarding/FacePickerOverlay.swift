import SwiftUI
import Vision
import CoreImage

/// When an enrollment photo has multiple faces, let the user tap the correct one.
struct FacePickerOverlay: View {
    let image: UIImage
    let personName: String
    let onFaceSelected: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var faceRects: [CGRect] = []
    @State private var selectedIndex: Int?
    @State private var isDetecting = true
    @State private var detectionError: String?

    var body: some View {
        VStack(spacing: Haya.Spacing.md) {
            // Header
            VStack(spacing: Haya.Spacing.xs) {
                Text("Which one is \(personName)?")
                    .font(HayaFont.title3)
                    .foregroundStyle(Haya.Colors.textCream)
                Text("Tap the correct face")
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textSageDim)
            }
            .padding(.top, Haya.Spacing.md)

            // Image with face overlays
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    if isDetecting {
                        ProgressView()
                            .tint(Haya.Colors.accentOrange)
                    } else {
                        GeometryReader { overlayGeo in
                            faceOverlays(in: overlayGeo.size)
                        }
                    }
                }
                .padding(.horizontal, Haya.Spacing.md)

            if let error = detectionError {
                Text(error)
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.accentRose)
                    .padding(.horizontal, Haya.Spacing.lg)
            }

            // Actions
            HStack(spacing: Haya.Spacing.md) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.hayaPillSecondary)

                Button("Confirm") {
                    guard let idx = selectedIndex, idx < faceRects.count else { return }
                    onFaceSelected(faceRects[idx])
                }
                .buttonStyle(.hayaPill)
                .disabled(selectedIndex == nil)
            }
            .padding(.horizontal, Haya.Spacing.lg)
            .padding(.bottom, Haya.Spacing.lg)
        }
        .sageBackground()
        .task {
            await detectFaces()
        }
    }

    // MARK: - Face Overlays

    @ViewBuilder
    private func faceOverlays(in size: CGSize) -> some View {
        // The overlay GeometryReader gives us the exact Image display size.
        // No offset needed — coordinate space matches 1:1.
        ForEach(faceRects.indices, id: \.self) { index in
            let r = faceRects[index]
            // Vision uses bottom-left origin, convert to top-left
            let x = r.origin.x * size.width
            let y = (1 - r.origin.y - r.height) * size.height
            let w = r.width * size.width
            let h = r.height * size.height

            let isSelected = selectedIndex == index

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Haya.Colors.accentOrange : Haya.Colors.textCream.opacity(0.6),
                    lineWidth: isSelected ? 3 : 2
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Haya.Colors.accentOrange.opacity(0.2) : .clear)
                )
                .frame(width: w, height: h)
                .position(x: x + w / 2, y: y + h / 2)
                .onTapGesture {
                    withAnimation(Haya.Motion.quick) {
                        selectedIndex = index
                    }
                }
        }
    }

    // MARK: - Face Detection

    private func detectFaces() async {
        guard let cgImage = image.cgImage else {
            isDetecting = false
            return
        }

        let request = VNDetectFaceRectanglesRequest()
        // Pass UIImage orientation so Vision returns rects matching the displayed image
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
            if let results = request.results, !results.isEmpty {
                faceRects = results.map { $0.boundingBox }
            } else {
                detectionError = "No faces detected. Try a different photo."
            }
        } catch {
            detectionError = "Could not detect faces. Try a different photo."
        }

        isDetecting = false
    }
}

// MARK: - UIImage Orientation → CGImagePropertyOrientation

extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up:            self = .up
        case .upMirrored:    self = .upMirrored
        case .down:          self = .down
        case .downMirrored:  self = .downMirrored
        case .left:          self = .left
        case .leftMirrored:  self = .leftMirrored
        case .right:         self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
