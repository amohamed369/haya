import Foundation
import Photos
import CoreImage
import os

private let logger = Logger(subsystem: "com.haya.app", category: "ScanEngine")

/// Scans the photo library asynchronously in batches, starting from most recent photos.
/// Runs while the app is in the foreground; not a true background task.
actor ScanEngine {
    private unowned let pipeline: Pipeline
    private var isRunning = false
    private var results: [String: PhotoFilterResult] = [:]
    private var progressContinuation: AsyncStream<ScanProgress>.Continuation?
    private var _progressStream: AsyncStream<ScanProgress>?

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
    }

    /// Stream of progress updates. Creates a new stream if the previous one was finished.
    var progressStream: AsyncStream<ScanProgress> {
        if let existing = _progressStream { return existing }
        let stream = AsyncStream<ScanProgress> { continuation in
            self.progressContinuation = continuation
        }
        _progressStream = stream
        return stream
    }

    /// Reset the stream so the next caller gets a fresh one.
    private func finishProgressStream() {
        progressContinuation?.finish()
        progressContinuation = nil
        _progressStream = nil
    }

    /// Current results keyed by asset local identifier.
    var currentResults: [String: PhotoFilterResult] { results }

    /// Start scanning from most recent photos.
    func startScan(batchSize: Int = 20) async {
        guard !isRunning else { return }
        isRunning = true

        logger.info("Starting scan with batch size \(batchSize)")
        await LogStore.shared.log(.info, "Scan", "Starting scan — batch size \(batchSize)")

        // Fetch all image assets, most recent first
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        let total = allAssets.count
        var processed = 0
        var hidden = 0
        var kept = 0
        var errors = 0

        emitProgress(ScanProgress(total: total, processed: 0, hidden: 0, kept: 0, errors: 0, isScanning: true))

        // Process in batches
        var batchStart = 0
        while batchStart < total && isRunning {
            let batchEnd = min(batchStart + batchSize, total)
            var batch: [PHAsset] = []
            for i in batchStart..<batchEnd {
                batch.append(allAssets.object(at: i))
            }

            for asset in batch {
                guard isRunning else { break }

                // Skip already-processed
                if results[asset.localIdentifier] != nil {
                    processed += 1
                    continue
                }

                // Load image
                guard let ciImage = await loadImage(asset) else {
                    await LogStore.shared.log(.warning, "Scan", "Failed to load image: \(asset.localIdentifier.prefix(8))...")
                    errors += 1
                    processed += 1
                    emitProgress(ScanProgress(total: total, processed: processed, hidden: hidden, kept: kept, errors: errors, isScanning: true))
                    continue
                }

                // Process through pipeline
                let result = await pipeline.processPhoto(ciImage, asset: asset)
                results[asset.localIdentifier] = result

                processed += 1
                switch result.overallDecision {
                case .hide: hidden += 1
                case .keep: kept += 1
                case .unknown: kept += 1
                case .error: errors += 1
                }

                emitProgress(ScanProgress(total: total, processed: processed, hidden: hidden, kept: kept, errors: errors, isScanning: true))
            }

            batchStart = batchEnd

            // Yield between batches to let UI breathe
            try? await Task.sleep(for: .milliseconds(100))
        }

        isRunning = false
        emitProgress(ScanProgress(total: total, processed: processed, hidden: hidden, kept: kept, errors: errors, isScanning: false))
        finishProgressStream()
        logger.info("Scan complete: \(processed)/\(total) processed, \(hidden) hidden, \(errors) errors")
        await LogStore.shared.log(.info, "Scan", "Complete: \(processed)/\(total) processed, \(hidden) hidden, \(errors) errors")
    }

    /// Stop an active scan.
    func stopScan() {
        isRunning = false
        finishProgressStream()
    }

    /// Clear all results for a fresh rescan.
    func clearResults() {
        results = [:]
    }

    /// Check if a photo has been scanned.
    func resultFor(assetID: String) -> PhotoFilterResult? {
        results[assetID]
    }

    // MARK: - Private

    private func emitProgress(_ progress: ScanProgress) {
        progressContinuation?.yield(progress)
    }

    private func loadImage(_ asset: PHAsset) async -> CIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let targetSize = CGSize(width: 1200, height: 1200)

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize,
                contentMode: .aspectFit, options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                if let cgImage = image?.cgImage {
                    continuation.resume(returning: CIImage(cgImage: cgImage))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
