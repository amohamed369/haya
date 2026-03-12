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

    // MARK: - VERDICT Format (Primary Path — Kaggle-aligned)

    func testParsesVerdictYES() {
        let text = """
        HEAD/HAIR: hijab visible → covered
        ARMS: long sleeves → covered
        VERDICT: YES (all covered)
        """
        let result = service.parseModestyResponse(text)
        XCTAssertTrue(result.isModest)
    }

    func testParsesVerdictNO() {
        let text = """
        HEAD/HAIR: bare head → not covered
        ARMS: short sleeves → bare skin visible
        VERDICT: NO (bare skin/hair visible)
        """
        let result = service.parseModestyResponse(text)
        XCTAssertFalse(result.isModest)
    }

    func testVerdictOnlyLastLine() {
        // "no" appears in reasoning but VERDICT is YES — should be modest
        let text = """
        HEAD/HAIR: no visible hair → covered
        ARMS: no bare skin → covered
        VERDICT: YES
        """
        let result = service.parseModestyResponse(text)
        XCTAssertTrue(result.isModest)
    }

    func testVerdictNOIgnoresReasoningYES() {
        // "yes" appears in reasoning but VERDICT is NO — should NOT be modest
        let text = """
        HEAD/HAIR: yes hijab present but loose
        ARMS: bare forearms visible
        VERDICT: NO (arms not fully covered)
        """
        let result = service.parseModestyResponse(text)
        XCTAssertFalse(result.isModest)
    }

    // MARK: - Single-Line YES/NO (Legacy/Simple Format)

    func testParsesSingleLineYES() {
        let result = service.parseModestyResponse("YES, high confidence, wearing hijab")
        XCTAssertTrue(result.isModest)
    }

    func testParsesSingleLineNO() {
        let result = service.parseModestyResponse("NO, low confidence, hair exposed")
        XCTAssertFalse(result.isModest)
    }

    // MARK: - Keyword Fallback (No YES/NO in last line)

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
        let result = service.parseModestyResponse("VERDICT: YES, HIGH confidence")
        XCTAssertEqual(result.confidence, .high)
    }

    func testConfidenceLow() {
        let result = service.parseModestyResponse("VERDICT: NO, LOW confidence")
        XCTAssertEqual(result.confidence, .low)
    }

    func testConfidenceMedium() {
        let result = service.parseModestyResponse("VERDICT: YES")
        XCTAssertEqual(result.confidence, .medium)
    }

    // MARK: - Edge Cases

    func testEmptyResponse() {
        let result = service.parseModestyResponse("")
        // Conservative: empty → not modest (privacy app defaults to hide)
        XCTAssertFalse(result.isModest)
    }

    func testReasonExtractsLastLine() {
        let text = """
        HEAD/HAIR: hijab visible → covered
        ARMS: long sleeves → covered
        VERDICT: YES (all covered)
        """
        let result = service.parseModestyResponse(text)
        XCTAssertEqual(result.reason, "VERDICT: YES (all covered)")
    }

    func testPunctuationInVerdict() {
        // YES with comma/period should still match
        let result = service.parseModestyResponse("VERDICT: YES.")
        XCTAssertTrue(result.isModest)
    }

    func testVerdictCaseInsensitive() {
        let result = service.parseModestyResponse("Verdict: No, arms exposed")
        XCTAssertFalse(result.isModest)
    }
}
