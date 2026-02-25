import Foundation
import CoreGraphics
import CoreImage
import Vision

/// Aligns a detected face to a canonical 112x112 position for ArcFace embedding.
/// Uses 5-point landmarks (left eye, right eye, nose, left mouth, right mouth)
/// with a similarity transform (rotation + uniform scale + translation).
enum FaceAligner {
    /// Canonical ArcFace target positions for 112x112 output.
    /// Order: left eye, right eye, nose tip, left mouth corner, right mouth corner.
    private static let canonicalPoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    static let outputSize = CGSize(width: 112, height: 112)

    /// Extract the 5 key landmark points from a VNFaceObservation.
    /// Vision landmarks use normalized coordinates within the face bounding box, origin bottom-left.
    static func extractKeyPoints(from face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let landmarks = face.landmarks else { return nil }

        // Use leftPupil/rightPupil for precise eye centers (Apple Vision API)
        // Fallback to leftEye/rightEye region centroids if pupils unavailable
        guard let nose = landmarks.nose,
              let outerLips = landmarks.outerLips else { return nil }

        let bb = face.boundingBox

        func toImage(_ pt: CGPoint) -> CGPoint {
            VisionCoordinates.convertPoint(pt, in: bb, imageSize: imageSize)
        }

        // Eye centers: prefer pupil points (single point, most accurate)
        let leftEyeCenter: CGPoint
        let rightEyeCenter: CGPoint
        if let lp = landmarks.leftPupil, let rp = landmarks.rightPupil,
           !lp.normalizedPoints.isEmpty, !rp.normalizedPoints.isEmpty {
            leftEyeCenter = toImage(lp.normalizedPoints[0])
            rightEyeCenter = toImage(rp.normalizedPoints[0])
        } else if let le = landmarks.leftEye, let re = landmarks.rightEye,
                  !le.normalizedPoints.isEmpty, !re.normalizedPoints.isEmpty {
            leftEyeCenter = centroid(le.normalizedPoints.map { toImage($0) })
            rightEyeCenter = centroid(re.normalizedPoints.map { toImage($0) })
        } else {
            return nil
        }

        let nosePoints = nose.normalizedPoints
        let lipPoints = outerLips.normalizedPoints
        guard !nosePoints.isEmpty, lipPoints.count >= 6 else { return nil }

        // Nose tip = middle point of nose constellation
        let noseTip = toImage(nosePoints[nosePoints.count / 2])
        // Mouth corners = first and midpoint of outer lips ring
        let leftMouth = toImage(lipPoints[0])
        let rightMouth = toImage(lipPoints[lipPoints.count / 2])

        return [leftEyeCenter, rightEyeCenter, noseTip, leftMouth, rightMouth]
    }

    /// Compute a similarity transform (rotation + uniform scale + translation) from source to target points.
    /// Uses least-squares fit for the 5-point correspondences.
    static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        guard src.count == dst.count, src.count >= 2 else { return .identity }

        let n = src.count
        // Compute using Umeyama algorithm (simplified for 2D similarity)
        var srcMean = CGPoint.zero
        var dstMean = CGPoint.zero
        for i in 0..<n {
            srcMean.x += src[i].x
            srcMean.y += src[i].y
            dstMean.x += dst[i].x
            dstMean.y += dst[i].y
        }
        srcMean.x /= CGFloat(n)
        srcMean.y /= CGFloat(n)
        dstMean.x /= CGFloat(n)
        dstMean.y /= CGFloat(n)

        var srcVar: CGFloat = 0
        var cov00: CGFloat = 0, cov01: CGFloat = 0
        var cov10: CGFloat = 0, cov11: CGFloat = 0

        for i in 0..<n {
            let sx = src[i].x - srcMean.x
            let sy = src[i].y - srcMean.y
            let dx = dst[i].x - dstMean.x
            let dy = dst[i].y - dstMean.y
            srcVar += sx * sx + sy * sy
            cov00 += dx * sx
            cov01 += dx * sy
            cov10 += dy * sx
            cov11 += dy * sy
        }

        // SVD of covariance matrix for 2x2
        // For similarity transform: scale * rotation matrix
        let a = cov00, b = cov01, c = cov10, d = cov11
        let det = a * d - b * c
        let sign: CGFloat = det >= 0 ? 1 : -1

        let s = sqrt(max(0, (a * a + b * b + c * c + d * d + 2 * sign * det)))

        let cosAngle: CGFloat
        let sinAngle: CGFloat
        if s > 1e-10 {
            cosAngle = (a + sign * d) / s
            sinAngle = (c - sign * b) / s
        } else {
            cosAngle = 1
            sinAngle = 0
        }

        let scale = srcVar > 1e-10 ? s / srcVar : 1

        let tx = dstMean.x - scale * (cosAngle * srcMean.x - sinAngle * srcMean.y)
        let ty = dstMean.y - scale * (sinAngle * srcMean.x + cosAngle * srcMean.y)

        return CGAffineTransform(
            a: scale * cosAngle, b: scale * sinAngle,
            c: -scale * sinAngle, d: scale * cosAngle,
            tx: tx, ty: ty
        )
    }

    /// Align a face from the source CIImage to a 112x112 crop suitable for ArcFace.
    static func alignFace(from image: CIImage, face: VNFaceObservation) -> CIImage? {
        let imageSize = image.extent.size
        guard let sourcePoints = extractKeyPoints(from: face, imageSize: imageSize) else {
            return nil
        }

        let transform = similarityTransform(from: sourcePoints, to: canonicalPoints)
        let aligned = image.transformed(by: transform)
        let cropRect = CGRect(origin: .zero, size: outputSize)
        return aligned.cropped(to: cropRect)
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var sum = CGPoint.zero
        for p in points {
            sum.x += p.x
            sum.y += p.y
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
