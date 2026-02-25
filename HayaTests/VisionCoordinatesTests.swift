import XCTest
@testable import Haya

final class VisionCoordinatesTests: XCTestCase {

    // MARK: - flipToTopLeft

    func testFlipToTopLeft_bottomOrigin() {
        // Vision rect at bottom: x=0.1, y=0 (bottom-left origin), w=0.3, h=0.2
        // Flipped: y = 1.0 - 0 - 0.2 = 0.8
        let visionRect = CGRect(x: 0.1, y: 0, width: 0.3, height: 0.2)
        let result = VisionCoordinates.flipToTopLeft(visionRect)
        XCTAssertEqual(result.origin.x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(result.origin.y, 0.8, accuracy: 1e-6)
        XCTAssertEqual(result.width, 0.3, accuracy: 1e-6)
        XCTAssertEqual(result.height, 0.2, accuracy: 1e-6)
    }

    func testFlipToTopLeft_center() {
        // Centered rect: x=0.25, y=0.25, w=0.5, h=0.5
        // Flipped: y = 1.0 - 0.25 - 0.5 = 0.25
        let visionRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let result = VisionCoordinates.flipToTopLeft(visionRect)
        XCTAssertEqual(result.origin.y, 0.25, accuracy: 1e-6)
    }

    // MARK: - convertToImageRect

    func testConvertToImageRect() {
        // Vision rect: x=0.1, y=0.2, w=0.3, h=0.4 in 100x100 image
        let visionRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let imageSize = CGSize(width: 100, height: 100)
        let result = VisionCoordinates.convertToImageRect(visionRect, imageSize: imageSize)
        // x = 0.1 * 100 = 10
        XCTAssertEqual(result.origin.x, 10, accuracy: 1e-6)
        // y = (1.0 - 0.2 - 0.4) * 100 = 40
        XCTAssertEqual(result.origin.y, 40, accuracy: 1e-6)
        // w = 0.3 * 100 = 30
        XCTAssertEqual(result.width, 30, accuracy: 1e-6)
        // h = 0.4 * 100 = 40
        XCTAssertEqual(result.height, 40, accuracy: 1e-6)
    }

    // MARK: - toCIImageRect

    func testToCIImageRect() {
        // Top-left normalized rect: x=0.1, y=0.2, w=0.3, h=0.4
        // Convert to CIImage (bottom-left pixels) in 100x100:
        // x = 0.1 * 100 = 10
        // y = (1.0 - 0.2 - 0.4) * 100 = 40
        let topLeftRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let imageSize = CGSize(width: 100, height: 100)
        let result = VisionCoordinates.toCIImageRect(topLeftRect, imageSize: imageSize)
        XCTAssertEqual(result.origin.x, 10, accuracy: 1e-6)
        XCTAssertEqual(result.origin.y, 40, accuracy: 1e-6)
        XCTAssertEqual(result.width, 30, accuracy: 1e-6)
        XCTAssertEqual(result.height, 40, accuracy: 1e-6)
    }

    func testToCIImageRect_topOfImage() {
        // y=0 in top-left means top of image → should be near bottom in CIImage (high y)
        let topLeftRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.2)
        let imageSize = CGSize(width: 200, height: 200)
        let result = VisionCoordinates.toCIImageRect(topLeftRect, imageSize: imageSize)
        // y = (1.0 - 0 - 0.2) * 200 = 160
        XCTAssertEqual(result.origin.y, 160, accuracy: 1e-6)
    }

    // MARK: - convertPoint

    func testConvertPoint() {
        // Landmark at center of a bounding box
        let point = CGPoint(x: 0.5, y: 0.5)
        let boundingBox = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)
        let imageSize = CGSize(width: 100, height: 100)
        let result = VisionCoordinates.convertPoint(point, in: boundingBox, imageSize: imageSize)
        // absoluteX = (0.2 + 0.5 * 0.4) * 100 = (0.2 + 0.2) * 100 = 40
        XCTAssertEqual(result.x, 40, accuracy: 1e-6)
        // absoluteY = (1.0 - (0.3 + 0.5 * 0.4)) * 100 = (1.0 - 0.5) * 100 = 50
        XCTAssertEqual(result.y, 50, accuracy: 1e-6)
    }
}
