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
            GeometryReader { geo in
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .overlay {
                            if isDetecting {
                                ProgressView()
                                    .tint(Haya.Colors.accentOrange)
                            } else {
                                faceOverlays(in: geo.size)
                            }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private func faceOverlays(in viewSize: CGSize) -> some View {
        let imageSize = image.size
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        let displaySize: CGSize
        if imageAspect > viewAspect {
            displaySize = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        } else {
            displaySize = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        }

        let offsetX = (viewSize.width - displaySize.width) / 2
        let offsetY = (viewSize.height - displaySize.height) / 2

        ForEach(faceRects.indices, id: \.self) { index in
            let normalizedRect = faceRects[index]
            // Vision uses bottom-left origin, convert to top-left
            let x = normalizedRect.origin.x * displaySize.width + offsetX
            let y = (1 - normalizedRect.origin.y - normalizedRect.height) * displaySize.height + offsetY
            let w = normalizedRect.width * displaySize.width
            let h = normalizedRect.height * displaySize.height

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
                    withAnimation(.spring(response: 0.3)) {
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
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            if let results = request.results {
                faceRects = results.map { $0.boundingBox }
            }
        } catch {
            // Detection failed — no faces to show
        }

        isDetecting = false
    }
}
