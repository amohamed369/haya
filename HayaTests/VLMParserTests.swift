import XCTest
@testable import Haya

@MainActor
final class VLMParserTests: XCTestCase {

    private var service: VLMService!

    override func setUp() {
        super.setUp()
        service = VLMService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - YES/NO Prefix

    func testParsesYESPrefix() {
        let result = service.parseModestyResponse("YES, high confidence, wearing hijab")
        XCTAssertTrue(result.isModest)
    }

    func testParsesNOPrefix() {
        let result = service.parseModestyResponse("NO, low confidence, hair exposed")
        XCTAssertFalse(result.isModest)
    }

    // MARK: - False Positive Prevention

    func testNOBODYNotFalsePositive() {
        // First word is "NOBODY", not "NO" — falls through to keyword fallback
        // "modest" keyword found → isModest = true
        let result = service.parseModestyResponse("NOBODY is immodest here")
        XCTAssertTrue(result.isModest)
    }

    func testNONENotFalsePositive() {
        // First word is "NONE", not "NO" — falls through to keyword fallback
        // "immodest" keyword found → immodestScore=1, modestScore=0 → isModest=false
        let result = service.parseModestyResponse("NONE of the clothing is immodest")
        XCTAssertFalse(result.isModest)
    }

    // MARK: - Keyword Fallback

    func testKeywordFallbackModest() {
        let result = service.parseModestyResponse("The person appears covered and modest")
        XCTAssertTrue(result.isModest)
    }

    func testKeywordFallbackImmodest() {
        let result = service.parseModestyResponse("Hair is exposed and revealing outfit")
        XCTAssertFalse(result.isModest)
    }

    // MARK: - Confidence

    func testConfidenceHigh() {
        let result = service.parseModestyResponse("YES, HIGH confidence, fully covered")
        XCTAssertEqual(result.confidence, "high")
    }

    func testConfidenceLow() {
        let result = service.parseModestyResponse("NO, LOW confidence, unclear image")
        XCTAssertEqual(result.confidence, "low")
    }

    func testConfidenceMedium() {
        let result = service.parseModestyResponse("YES, person is wearing hijab")
        XCTAssertEqual(result.confidence, "medium")
    }

    // MARK: - Edge Cases

    func testEmptyResponse() {
        let result = service.parseModestyResponse("")
        XCTAssertFalse(result.isModest)
    }

    func testReasonExtractsLastLine() {
        let text = """
        YES, high confidence
        The person is wearing a hijab
        Arms and legs are fully covered
        """
        let result = service.parseModestyResponse(text)
        XCTAssertEqual(result.reason, "Arms and legs are fully covered")
    }
}
