import Foundation
import CoreImage
import Vision

/// Result of hair segmentation analysis.
struct HairSegmentationResult: Sendable {
    let hairRatio: Float
    static let hairThreshold: Float = 0.15

    var hairVisible: Bool { hairRatio > Self.hairThreshold }
    var skipVLM: Bool { hairVisible }
}

/// Hair segmentation to pre-filter before VLM.
/// MVP uses Apple Vision person segmentation + head region analysis.
/// Future: swap in MediaPipe hair_segmenter.tflite for precise hair-vs-covering distinction.
actor HairSegmenter {
    private let ciContext = CIContext()

    func analyze(person: DetectedPerson, in image: CIImage) async throws -> HairSegmentationResult {
        let imageSize = image.extent.size

        let headRect: CGRect
        if let faceObs = person.faceObservation {
            // Vision and CIImage both use bottom-left origin, so multiply directly (no Y-flip needed)
            let facePixelRect = CGRect(
                x: faceObs.boundingBox.origin.x * imageSize.width,
                y: faceObs.boundingBox.origin.y * imageSize.height,
                width: faceObs.boundingBox.width * imageSize.width,
                height: faceObs.boundingBox.height * imageSize.height
            )
            let hairHeight = facePixelRect.height * 0.8
            headRect = CGRect(
                x: facePixelRect.origin.x - facePixelRect.width * 0.3,
                y: facePixelRect.origin.y - facePixelRect.height * 0.2,
                width: facePixelRect.width * 1.6,
                height: facePixelRect.height + hairHeight
            ).intersection(image.extent)
        } else if let bodyBox = person.bodyBoundingBox {
            // bodyBoundingBox is top-left normalized — convert to CIImage bottom-left pixels
            let bodyRect = VisionCoordinates.toCIImageRect(bodyBox, imageSize: imageSize)
            // Upper 25% of body = head region (in CIImage coords, upper = higher Y)
            headRect = CGRect(
                x: bodyRect.origin.x,
                y: bodyRect.origin.y + bodyRect.height * 0.75,
                width: bodyRect.width,
                height: bodyRect.height * 0.25
            ).intersection(image.extent)
        } else {
            return HairSegmentationResult(hairRatio: 0)
        }

        guard headRect.width > 10, headRect.height > 10 else {
            return HairSegmentationResult(hairRatio: 0)
        }

        let headCrop = image.cropped(to: headRect)
        let hairRatio = try await estimateHairRatio(headCrop: headCrop)

        return HairSegmentationResult(hairRatio: hairRatio)
    }

    private func estimateHairRatio(headCrop: CIImage) async throws -> Float {
        let handler = VNImageRequestHandler(ciImage: headCrop, options: [:])
        let segRequest = VNGeneratePersonSegmentationRequest()
        segRequest.qualityLevel = .fast

        do {
            try handler.perform([segRequest])
        } catch {
            await LogStore.shared.log(.warning, "HairSeg", "Person segmentation failed: \(error.localizedDescription)")
            return 0
        }

        guard let mask = segRequest.results?.first?.pixelBuffer else { return 0 }

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else { return 0 }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(mask)

        var personPixels = 0
        var totalPixels = 0
        let upperHalf = height / 2

        for y in 0..<upperHalf {
            for x in 0..<width {
                totalPixels += 1
                if pixelFormat == kCVPixelFormatType_OneComponent8 {
                    let ptr = baseAddress.advanced(by: y * bytesPerRow + x)
                    let value = ptr.load(as: UInt8.self)
                    if value > 128 { personPixels += 1 }
                } else {
                    let ptr = baseAddress.advanced(by: y * bytesPerRow + x * 4)
                    let value = ptr.load(as: UInt8.self)
                    if value > 128 { personPixels += 1 }
                }
            }
        }

        guard totalPixels > 0 else { return 0 }
        return Float(personPixels) / Float(totalPixels)
    }
}
