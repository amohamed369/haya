import Foundation
import os

private let logger = Logger(subsystem: "com.haya.app", category: "CrashGuard")

/// Persists breadcrumb logs to disk so they survive crashes.
/// Detects crash loops and triggers safe mode to prevent repeated crashes.
///
/// Usage:
///   CrashGuard.shared.breadcrumb("Scan", "Starting detect() for photo 3")
///   CrashGuard.shared.markScanStarted()
///   // ... if app crashes here, next launch sees the breadcrumbs ...
///   CrashGuard.shared.markScanFinished()
final class CrashGuard {
    static let shared = CrashGuard()

    private let defaults = UserDefaults.standard

    // Keys
    private let kScanInProgress = "haya_scan_in_progress"
    private let kConsecutiveCrashes = "haya_consecutive_crashes"
    private let kSafeMode = "haya_safe_mode"
    private let kLastCrashBreadcrumbs = "haya_last_crash_breadcrumbs"

    // In-memory breadcrumb buffer (flushed to disk periodically)
    private var breadcrumbs: [String] = []
    private let maxBreadcrumbs = 50
    private let queue = DispatchQueue(label: "com.haya.crashguard")

    private init() {}

    // MARK: - Crash Loop Detection

    /// Call at app launch BEFORE starting any ML work.
    /// Returns true if safe mode is active (scan should be skipped).
    func checkOnLaunch() -> Bool {
        let wasScanning = defaults.bool(forKey: kScanInProgress)
        let crashes = defaults.integer(forKey: kConsecutiveCrashes)

        if wasScanning {
            // App crashed during scan
            let newCount = crashes + 1
            defaults.set(newCount, forKey: kConsecutiveCrashes)
            defaults.set(false, forKey: kScanInProgress)

            // Save breadcrumbs as "last crash" for diagnostics
            let currentBreadcrumbs = loadBreadcrumbsFromDisk()
            if !currentBreadcrumbs.isEmpty {
                defaults.set(currentBreadcrumbs, forKey: kLastCrashBreadcrumbs)
            }

            logger.error("Crash detected during scan (crash #\(newCount)). Breadcrumbs saved.")

            if newCount >= 2 {
                defaults.set(true, forKey: kSafeMode)
                logger.error("Safe mode ACTIVATED after \(newCount) consecutive crashes")
            }
        } else {
            // Clean launch — reset crash counter
            defaults.set(0, forKey: kConsecutiveCrashes)
        }

        // Clear breadcrumb file for fresh session
        clearBreadcrumbFile()

        return defaults.bool(forKey: kSafeMode)
    }

    /// Mark that a scan is starting (set crash canary).
    func markScanStarted() {
        defaults.set(true, forKey: kScanInProgress)
        defaults.synchronize()
        breadcrumb("Scan", "Scan started")
    }

    /// Mark that scan completed successfully (clear crash canary).
    func markScanFinished() {
        defaults.set(false, forKey: kScanInProgress)
        defaults.set(0, forKey: kConsecutiveCrashes)
        defaults.synchronize()
        breadcrumb("Scan", "Scan finished OK")
    }

    /// Mark that a single photo was processed (partial progress).
    func markPhotoProcessed() {
        // Periodically flush to disk so we know where we got to
        flushToDisk()
    }

    // MARK: - Safe Mode

    var isSafeMode: Bool {
        defaults.bool(forKey: kSafeMode)
    }

    /// User can manually exit safe mode (e.g., after an iOS update).
    func exitSafeMode() {
        defaults.set(false, forKey: kSafeMode)
        defaults.set(0, forKey: kConsecutiveCrashes)
        defaults.synchronize()
    }

    var consecutiveCrashes: Int {
        defaults.integer(forKey: kConsecutiveCrashes)
    }

    // MARK: - Breadcrumbs

    /// Add a breadcrumb — survives crashes via periodic disk flush.
    func breadcrumb(_ category: String, _ message: String) {
        let ts = Self.timestampString()
        let line = "[\(ts)] [\(category)] \(message)"
        logger.info("\(line)")

        queue.sync {
            breadcrumbs.append(line)
            if breadcrumbs.count > maxBreadcrumbs {
                breadcrumbs.removeFirst()
            }
        }

        // Flush every 5 breadcrumbs
        if breadcrumbs.count % 5 == 0 {
            flushToDisk()
        }
    }

    /// Get last crash breadcrumbs (from previous crashed session).
    var lastCrashBreadcrumbs: [String] {
        defaults.stringArray(forKey: kLastCrashBreadcrumbs) ?? []
    }

    /// Get current session breadcrumbs.
    var currentBreadcrumbs: [String] {
        queue.sync { breadcrumbs }
    }

    // MARK: - Disk Persistence

    private var breadcrumbFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("haya_breadcrumbs.log")
    }

    /// Force flush breadcrumbs to disk (call before risky operations).
    func flushToDisk() {
        let lines: [String] = queue.sync { breadcrumbs }
        let text = lines.joined(separator: "\n")
        try? text.write(to: breadcrumbFileURL, atomically: true, encoding: .utf8)
    }

    private func loadBreadcrumbsFromDisk() -> [String] {
        guard let text = try? String(contentsOf: breadcrumbFileURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func clearBreadcrumbFile() {
        try? FileManager.default.removeItem(at: breadcrumbFileURL)
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    // MARK: - Diagnostic Summary

    /// Human-readable crash diagnostic for display in Activity/Settings.
    func diagnosticSummary() -> String {
        var lines: [String] = []
        lines.append("Consecutive crashes: \(consecutiveCrashes)")
        lines.append("Safe mode: \(isSafeMode ? "ON" : "OFF")")

        let ios = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("iOS: \(ios.majorVersion).\(ios.minorVersion).\(ios.patchVersion)")

        let lastCrumbs = lastCrashBreadcrumbs
        if !lastCrumbs.isEmpty {
            lines.append("")
            lines.append("--- Last crash breadcrumbs ---")
            for crumb in lastCrumbs.suffix(20) {
                lines.append(crumb)
            }
        } else {
            lines.append("No crash breadcrumbs recorded.")
        }

        return lines.joined(separator: "\n")
    }
}
