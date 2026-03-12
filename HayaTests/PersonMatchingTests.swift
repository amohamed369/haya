import XCTest
@testable import Haya

final class PersonMatchingTests: XCTestCase {

    // MARK: - Strong Face Match (>= 0.35)

    func testStrongFaceMatchSucceeds() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: 0.40, bodySimilarity: 0.50, hasFace: true)
        XCTAssertTrue(r.matched)
        XCTAssertTrue(r.useFace)
        XCTAssertEqual(r.source, "face")
    }

    func testFaceExactThresholdSucceeds() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: 0.35, bodySimilarity: 0, hasFace: true)
        XCTAssertTrue(r.matched)
        XCTAssertTrue(r.useFace)
    }

    // MARK: - Body Override (face < 0.35, body >= 0.90)

    func testBodyOverrideWithWrongFace() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: 0.20, bodySimilarity: 0.92, hasFace: true)
        XCTAssertTrue(r.matched)
        XCTAssertFalse(r.useFace)
        XCTAssertEqual(r.source, "body_override")
    }

    func testBodyOverrideExactThreshold() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: 0.20, bodySimilarity: 0.90, hasFace: true)
        XCTAssertTrue(r.matched)
        XCTAssertEqual(r.source, "body_override")
    }

    func testBodyOverrideFailsBelowThreshold() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: 0.20, bodySimilarity: 0.89, hasFace: true)
        XCTAssertFalse(r.matched)
    }

    // MARK: - Body Only (no face, >= 0.80)

    func testBodyOnlyMatchSucceeds() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: nil, bodySimilarity: 0.85, hasFace: false)
        XCTAssertTrue(r.matched)
        XCTAssertFalse(r.useFace)
        XCTAssertEqual(r.source, "body")
    }

    func testBodyOnlyExactThreshold() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: nil, bodySimilarity: 0.80, hasFace: false)
        XCTAssertTrue(r.matched)
    }

    func testBodyOnlyBelowThresholdFails() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: nil, bodySimilarity: 0.79, hasFace: false)
        XCTAssertFalse(r.matched)
    }

    // MARK: - No Match

    func testNoMatchWhenBothLow() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: 0.10, bodySimilarity: 0.30, hasFace: true)
        XCTAssertFalse(r.matched)
        XCTAssertEqual(r.source, "none")
    }

    func testNoMatchWhenBothNil() {
        let r = PersonIdentifier.matchPerson(faceSimilarity: nil, bodySimilarity: nil, hasFace: false)
        XCTAssertFalse(r.matched)
    }
}
