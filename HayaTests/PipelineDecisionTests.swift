import XCTest
@testable import Haya

@MainActor
final class PipelineDecisionTests: XCTestCase {

    private func makeResult(decision: FilterDecision) -> PersonFilterResult {
        PersonFilterResult(
            person: DetectedPerson(
                boundingBox: .zero, faceObservation: nil, bodyBoundingBox: nil,
                personBox: .zero, personBoxSource: .yoloRaw, isMultiPerson: false,
                confidence: 0.9, source: .bodyOnly, instanceMaskIndex: nil
            ),
            identification: nil, hairSegResult: nil, modestyAssessment: nil,
            decision: decision, decisionReason: "test"
        )
    }

    func testNoPeopleReturnsKeep() {
        let result = Pipeline.overallDecision(for: [])
        XCTAssertEqual(result, .keep)
    }

    func testSingleKeepReturnsKeep() {
        let result = Pipeline.overallDecision(for: [makeResult(decision: .keep)])
        XCTAssertEqual(result, .keep)
    }

    func testSingleHideReturnsHide() {
        let result = Pipeline.overallDecision(for: [makeResult(decision: .hide)])
        XCTAssertEqual(result, .hide)
    }

    func testMixedKeepAndHideReturnsHide() {
        let results = [makeResult(decision: .keep), makeResult(decision: .hide)]
        XCTAssertEqual(Pipeline.overallDecision(for: results), .hide)
    }

    func testErrorReturnsHide() {
        let result = Pipeline.overallDecision(for: [makeResult(decision: .error("fail"))])
        XCTAssertEqual(result, .hide)
    }

    func testUnknownReturnsKeep() {
        let result = Pipeline.overallDecision(for: [makeResult(decision: .unknown)])
        XCTAssertEqual(result, .keep)
    }

    func testMixedUnknownAndHideReturnsHide() {
        let results = [makeResult(decision: .unknown), makeResult(decision: .hide)]
        XCTAssertEqual(Pipeline.overallDecision(for: results), .hide)
    }
}
