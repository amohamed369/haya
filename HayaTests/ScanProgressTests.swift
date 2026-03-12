import XCTest
@testable import Haya

final class ScanProgressTests: XCTestCase {

    func testPercentCompleteNormal() {
        let p = ScanProgress(total: 100, processed: 50, hidden: 10, kept: 40, errors: 0, isScanning: true)
        XCTAssertEqual(p.percentComplete, 0.5, accuracy: 0.001)
    }

    func testPercentCompleteZeroTotal() {
        let p = ScanProgress(total: 0, processed: 0, hidden: 0, kept: 0, errors: 0, isScanning: false)
        XCTAssertEqual(p.percentComplete, 0)
    }

    func testPercentCompleteFullyProcessed() {
        let p = ScanProgress(total: 200, processed: 200, hidden: 50, kept: 150, errors: 0, isScanning: false)
        XCTAssertEqual(p.percentComplete, 1.0, accuracy: 0.001)
    }

    func testPendingNormal() {
        let p = ScanProgress(total: 100, processed: 30, hidden: 5, kept: 25, errors: 0, isScanning: true)
        XCTAssertEqual(p.pending, 70)
    }

    func testPendingZeroWhenComplete() {
        let p = ScanProgress(total: 50, processed: 50, hidden: 10, kept: 40, errors: 0, isScanning: false)
        XCTAssertEqual(p.pending, 0)
    }

    func testIdleState() {
        let p = ScanProgress.idle
        XCTAssertEqual(p.total, 0)
        XCTAssertEqual(p.processed, 0)
        XCTAssertFalse(p.isScanning)
    }
}
