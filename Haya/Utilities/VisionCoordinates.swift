import Foundation
import Vision
import CoreGraphics

/// Converts between Apple Vision coordinate system (origin bottom-left, normalized 0-1)
/// and UIKit/SwiftUI coordinate system (origin top-left).
enum VisionCoordinates {
    /// Convert a Vision normalized rect to a CGRect in an image of the given size.
    /// Vision origin is bottom-left; this flips to top-left origin (UIKit/SwiftUI).
    static func convertToImageRect(_ visionRect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: visionRect.origin.x * imageSize.width,
            y: (1.0 - visionRect.origin.y - visionRect.height) * imageSize.height,
            width: visionRect.width * imageSize.width,
            height: visionRect.height * imageSize.height
        )
    }

    /// Convert a Vision normalized rect to SwiftUI-compatible normalized rect (0-1, top-left origin).
    static func flipToTopLeft(_ visionRect: CGRect) -> CGRect {
        CGRect(
            x: visionRect.origin.x,
            y: 1.0 - visionRect.origin.y - visionRect.height,
            width: visionRect.width,
            height: visionRect.height
        )
    }

    /// Convert a top-left normalized rect (as stored in DetectedPerson.boundingBox)
    /// to CIImage pixel coordinates (bottom-left origin).
    /// Use this when cropping CIImages with rects that were already flipped to top-left.
    static func toCIImageRect(_ topLeftNormalized: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: topLeftNormalized.origin.x * imageSize.width,
            y: (1.0 - topLeftNormalized.origin.y - topLeftNormalized.height) * imageSize.height,
            width: topLeftNormalized.width * imageSize.width,
            height: topLeftNormalized.height * imageSize.height
        )
    }

    /// Convert a Vision landmark point (normalized, bottom-left origin) to image coordinates.
    static func convertPoint(_ point: CGPoint, in boundingBox: CGRect, imageSize: CGSize) -> CGPoint {
        let absoluteX = (boundingBox.origin.x + point.x * boundingBox.width) * imageSize.width
        let absoluteY = (1.0 - (boundingBox.origin.y + point.y * boundingBox.height)) * imageSize.height
        return CGPoint(x: absoluteX, y: absoluteY)
    }
}
