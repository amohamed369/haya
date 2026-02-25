import Foundation

/// Progress of a photo library scan.
struct ScanProgress: Sendable {
    let total: Int
    let processed: Int
    let hidden: Int
    let kept: Int
    let errors: Int
    let isScanning: Bool

    var percentComplete: Double {
        guard total > 0 else { return 0 }
        return Double(processed) / Double(total)
    }

    var pending: Int {
        max(0, total - processed)
    }

    static let idle = ScanProgress(total: 0, processed: 0, hidden: 0, kept: 0, errors: 0, isScanning: false)
}
