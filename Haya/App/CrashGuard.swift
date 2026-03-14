import Foundation
import MetricKit
import os

private let logger = Logger(subsystem: "com.haya.app", category: "CrashGuard")

/// Persists breadcrumb logs to disk so they survive crashes.
/// Detects crash loops and triggers safe mode to prevent repeated crashes.
/// Integrates MetricKit to catch system-level kills (jetsam, watchdog).
///
/// Usage:
///   CrashGuard.shared.breadcrumb("Scan", "Starting detect() for photo 3")
///   CrashGuard.shared.markScanStarted()
///   CrashGuard.shared.markScanFinished()
final class CrashGuard: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashGuard()

    private let defaults = UserDefaults.standard

    // Keys
    private let kScanInProgress = "haya_scan_in_progress"
    private let kModelLoadInProgress = "haya_model_load_in_progress"
    private let kConsecutiveCrashes = "haya_consecutive_crashes"
    private let kSafeMode = "haya_safe_mode"
    private let kLastCrashBreadcrumbs = "haya_last_crash_breadcrumbs"
    private let kLastMetricKitDiag = "haya_last_metrickit_diag"
    private let kLastMemoryMB = "haya_last_memory_mb"

    // In-memory breadcrumb buffer (flushed to disk periodically)
    private var breadcrumbs: [String] = []
    private let maxBreadcrumbs = 50
    private let queue = DispatchQueue(label: "com.haya.crashguard")

    private override init() {
        super.init()
        // Subscribe to MetricKit diagnostics (crash reports, jetsam, hangs)
        MXMetricManager.shared.add(self)
    }

    // MARK: - MetricKit (catches system kills)

    /// Called by MetricKit on next launch after a crash/jetsam/hang.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var diagLines: [String] = []
        for payload in payloads {
            if let crashes = payload.crashDiagnostics {
                for crash in crashes {
                    let sig = crash.signal?.description ?? "unknown"
                    let code = crash.exceptionCode?.description ?? "?"
                    diagLines.append("CRASH: signal=\(sig) code=\(code) type=\(crash.terminationReason ?? "?")")
                    let tree = crash.callStackTree
                    diagLines.append("  callStack: \(String(data: tree.jsonRepresentation(), encoding: .utf8)?.prefix(500) ?? "?")")
                }
            }
            if let hangs = payload.hangDiagnostics {
                for hang in hangs {
                    diagLines.append("HANG: duration=\(hang.hangDuration)")
                }
            }
        }
        if !diagLines.isEmpty {
            defaults.set(diagLines, forKey: kLastMetricKitDiag)
            logger.error("MetricKit diagnostics received: \(diagLines.count) entries")
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // We mainly care about diagnostics, but log exit metrics if available
        for payload in payloads {
            if let exitMetrics = payload.applicationExitMetrics {
                let bg = exitMetrics.backgroundExitData
                let fg = exitMetrics.foregroundExitData
                let memKills = bg.cumulativeMemoryResourceLimitExitCount + fg.cumulativeMemoryResourceLimitExitCount
                let watchdog = fg.cumulativeAppWatchdogExitCount
                if memKills > 0 || watchdog > 0 {
                    breadcrumb("MetricKit", "Exit metrics: memoryKills=\(memKills) watchdog=\(watchdog)")
                    flushToDisk()
                }
            }
        }
    }

    // MARK: - Memory Monitoring

    /// Current available memory in MB. Uses os_proc_available_memory.
    static var availableMemoryMB: Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    /// Log current memory and return available MB.
    @discardableResult
    func logMemory(_ context: String) -> Int {
        let mb = Self.availableMemoryMB
        defaults.set(mb, forKey: kLastMemoryMB)
        breadcrumb("Memory", "\(context): \(mb) MB available")
        if mb < 100 {
            logger.warning("LOW MEMORY: \(mb) MB at \(context)")
            breadcrumb("Memory", "WARNING: LOW MEMORY \(mb) MB")
            flushToDisk()
        }
        return mb
    }

    // MARK: - Crash Loop Detection

    /// Call at app launch BEFORE starting any ML work.
    /// Returns true if safe mode is active (scan should be skipped).
    func checkOnLaunch() -> Bool {
        let wasScanning = defaults.bool(forKey: kScanInProgress)
        let wasLoadingModels = defaults.bool(forKey: kModelLoadInProgress)
        let crashes = defaults.integer(forKey: kConsecutiveCrashes)

        if wasScanning || wasLoadingModels {
            let phase = wasLoadingModels ? "model loading" : "scanning"
            let newCount = crashes + 1
            defaults.set(newCount, forKey: kConsecutiveCrashes)
            defaults.set(false, forKey: kScanInProgress)
            defaults.set(false, forKey: kModelLoadInProgress)

            // Save breadcrumbs as "last crash" for diagnostics
            let currentBreadcrumbs = loadBreadcrumbsFromDisk()
            if !currentBreadcrumbs.isEmpty {
                defaults.set(currentBreadcrumbs, forKey: kLastCrashBreadcrumbs)
            }

            let lastMem = defaults.integer(forKey: kLastMemoryMB)
            logger.error("Crash detected during \(phase) (crash #\(newCount), lastMem=\(lastMem)MB)")

            if newCount >= 2 {
                defaults.set(true, forKey: kSafeMode)
                logger.error("Safe mode ACTIVATED after \(newCount) consecutive crashes")
            }
        } else if !defaults.bool(forKey: kSafeMode) {
            // Clean launch AND not in safe mode — reset crash counter.
            // Don't reset if safe mode is active (preserve count for diagnostics).
            defaults.set(0, forKey: kConsecutiveCrashes)
        }

        // Clear breadcrumb file for fresh session
        clearBreadcrumbFile()

        return defaults.bool(forKey: kSafeMode)
    }

    /// Mark that model loading is starting.
    func markModelLoadStarted() {
        defaults.set(true, forKey: kModelLoadInProgress)
        defaults.synchronize()
        breadcrumb("Models", "Model loading started")
        logMemory("before model load")
    }

    /// Mark that model loading completed.
    func markModelLoadFinished() {
        defaults.set(false, forKey: kModelLoadInProgress)
        defaults.synchronize()
        breadcrumb("Models", "Model loading finished")
        logMemory("after model load")
    }

    /// Mark that a scan is starting (set crash canary).
    func markScanStarted() {
        defaults.set(true, forKey: kScanInProgress)
        defaults.synchronize()
        breadcrumb("Scan", "Scan started")
        logMemory("scan start")
    }

    /// Mark that scan completed successfully (clear crash canary).
    func markScanFinished() {
        defaults.set(false, forKey: kScanInProgress)
        defaults.set(0, forKey: kConsecutiveCrashes)
        defaults.synchronize()
        breadcrumb("Scan", "Scan finished OK")
        logMemory("scan end")
    }

    /// Mark that a single photo was processed (partial progress).
    func markPhotoProcessed() {
        flushToDisk()
    }

    // MARK: - Safe Mode

    var isSafeMode: Bool {
        defaults.bool(forKey: kSafeMode)
    }

    func exitSafeMode() {
        defaults.set(false, forKey: kSafeMode)
        defaults.set(0, forKey: kConsecutiveCrashes)
        defaults.synchronize()
    }

    var consecutiveCrashes: Int {
        defaults.integer(forKey: kConsecutiveCrashes)
    }

    // MARK: - Breadcrumbs

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

    var lastCrashBreadcrumbs: [String] {
        defaults.stringArray(forKey: kLastCrashBreadcrumbs) ?? []
    }

    var lastMetricKitDiagnostics: [String] {
        defaults.stringArray(forKey: kLastMetricKitDiag) ?? []
    }

    var currentBreadcrumbs: [String] {
        queue.sync { breadcrumbs }
    }

    // MARK: - Disk Persistence

    private var breadcrumbFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("haya_breadcrumbs.log")
    }

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

    func diagnosticSummary() -> String {
        var lines: [String] = []
        lines.append("Consecutive crashes: \(consecutiveCrashes)")
        lines.append("Safe mode: \(isSafeMode ? "ON" : "OFF")")
        lines.append("Current memory: \(Self.availableMemoryMB) MB available")
        lines.append("Last memory before crash: \(defaults.integer(forKey: kLastMemoryMB)) MB")

        let ios = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("iOS: \(ios.majorVersion).\(ios.minorVersion).\(ios.patchVersion)")

        let mkDiags = lastMetricKitDiagnostics
        if !mkDiags.isEmpty {
            lines.append("")
            lines.append("--- MetricKit diagnostics ---")
            for diag in mkDiags.suffix(5) {
                lines.append(diag)
            }
        }

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
