import XCTest
@testable import Haya

final class PersonBoxEstimationTests: XCTestCase {

    func testStandardFace() {
        let face = CGRect(x: 0.4, y: 0.1, width: 0.1, height: 0.08)
        let box = PersonDetector.estimatePersonBox(faceBox: face)
        // Body should be centered on face horizontally
        XCTAssertEqual(box.midX, face.midX, accuracy: 0.01)
        // Body should be wider than face
        XCTAssertGreaterThan(box.width, face.width)
        // Body should be taller than face
        XCTAssertGreaterThan(box.height, face.height)
    }

    func testFaceAtLeftEdgeClamped() {
        let face = CGRect(x: 0.0, y: 0.1, width: 0.1, height: 0.08)
        let box = PersonDetector.estimatePersonBox(faceBox: face)
        XCTAssertGreaterThanOrEqual(box.origin.x, 0)
        XCTAssertGreaterThanOrEqual(box.origin.y, 0)
    }

    func testFaceAtBottomEdgeClamped() {
        let face = CGRect(x: 0.4, y: 0.9, width: 0.1, height: 0.08)
        let box = PersonDetector.estimatePersonBox(faceBox: face)
        XCTAssertLessThanOrEqual(box.maxX, 1.0)
        XCTAssertLessThanOrEqual(box.maxY, 1.0)
    }

    func testCustomScale() {
        let face = CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.08)
        let box = PersonDetector.estimatePersonBox(faceBox: face, scale: 5.0)
        // Wider scale = wider body estimate
        XCTAssertGreaterThan(box.width, face.width * 4)
    }

    func testLargeFaceClamped() {
        let face = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5)
        let box = PersonDetector.estimatePersonBox(faceBox: face)
        XCTAssertGreaterThanOrEqual(box.origin.x, 0)
        XCTAssertLessThanOrEqual(box.maxX, 1.0)
        XCTAssertLessThanOrEqual(box.maxY, 1.0)
    }
}
