import Foundation
import Combine
import CoreImage
import Photos
import os

private let logger = Logger(subsystem: "com.haya.app", category: "Pipeline")

/// Per-person filter mode.
enum FilterMode: String, Codable, CaseIterable, Sendable {
    case defaultFilter = "default"   // Hair seg + VLM check
    case alwaysHide = "always_hide"  // Always hide this person
    case custom = "custom"           // Custom VLM prompt per person
}

/// Result of processing a single detected person through the pipeline.
struct PersonFilterResult: Identifiable, @unchecked Sendable {
    let id = UUID()
    let person: DetectedPerson
    let identification: IdentificationResult?
    let hairSegResult: HairSegmentationResult?
    let modestyAssessment: ModestyAssessment?
    let decision: FilterDecision
    let decisionReason: String
}

enum FilterDecision: Equatable, Sendable {
    case keep           // Show the photo
    case hide           // Hide the photo
    case unknown        // Could not determine (no enrolled person matched)
    case error(String)  // Pipeline error — fail-safe to hide
}

/// Full result of processing a photo through the pipeline.
struct PhotoFilterResult: @unchecked Sendable {
    let asset: PHAsset?
    let personResults: [PersonFilterResult]
    let overallDecision: FilterDecision
    let processingTimeMs: Int
}

/// Orchestrates the full ML pipeline: Detect → Identify → Hair Seg → VLM → Filter Decision.
@MainActor
class Pipeline: ObservableObject {
    let detector = PersonDetector()
    let identifier = PersonIdentifier()
    let hairSegmenter = HairSegmenter()
    let vlmService = VLMService()

    @Published var isReady = false
    @Published var detectorReady = false
    @Published var isEnrollReady = false
    @Published var isProcessing = false
    @Published var loadingStatus = "Not loaded"

    /// Scan engine for background photo processing.
    private(set) lazy var scanEngine = ScanEngine(pipeline: self)

    /// Live scan progress — updated by observing ScanEngine's stream.
    @Published var scanProgress = ScanProgress(total: 0, processed: 0, hidden: 0, kept: 0, errors: 0, isScanning: false)

    /// Scan results keyed by asset localIdentifier.
    @Published var scanResults: [String: PhotoFilterResult] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var scanListenerTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    init() {
        // Forward nested ObservableObject changes so SwiftUI re-renders
        vlmService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Start background scan and feed results back to published properties.
    func startBackgroundScan(batchSize: Int = 20) {
        // Don't scan if models aren't loaded — nothing useful can happen
        guard isReady else {
            LogStore.shared.log(.warning, "Pipeline", "Scan skipped — models not loaded")
            return
        }

        // Don't scan in safe mode (previous crash detected)
        guard !CrashGuard.shared.isSafeMode else {
            LogStore.shared.log(.warning, "Pipeline", "Scan skipped — safe mode active (previous crash)")
            return
        }

        // Cancel any previous listener to prevent duplicate streams
        scanListenerTask?.cancel()
        scanTask?.cancel()

        CrashGuard.shared.markScanStarted()

        scanTask = Task { [weak self] in
            guard let self else { return }
            let stream = await scanEngine.progressStream
            scanListenerTask = Task { [weak self] in
                for await progress in stream {
                    guard !Task.isCancelled else { break }
                    self?.scanProgress = progress
                    if let results = await self?.scanEngine.currentResults {
                        self?.scanResults = results
                    }
                }
            }
            await scanEngine.startScan(batchSize: batchSize)
            CrashGuard.shared.markScanFinished()
        }
    }

    /// Clear results and rescan everything.
    func rescanAll(batchSize: Int = 20) {
        Task {
            await scanEngine.stopScan()
            await scanEngine.clearResults()
            scanResults = [:]
            scanProgress = ScanProgress.idle
            startBackgroundScan(batchSize: batchSize)
        }
    }

    /// Load all models. Call once at app startup.
    /// Each model loads independently — one failure doesn't block the others.
    func loadModels() async {
        let log = LogStore.shared

        // 1. Detector (Vision faces + YOLO bodies)
        loadingStatus = "Loading detection models..."
        log.log(.info, "Pipeline", "Loading detection models...")
        do {
            try await detector.loadModels()
            detectorReady = true
            log.log(.info, "Pipeline", "Detection models loaded")
        } catch {
            log.log(.error, "Pipeline", "Detection model failed: \(error.localizedDescription)")
            logger.error("Detection model failed: \(error)")
        }

        // 2. Identifier (ArcFace + CLIPReID)
        loadingStatus = "Loading identification models..."
        log.log(.info, "Pipeline", "Loading identification models...")
        do {
            try await identifier.loadModels()
            isEnrollReady = true
            log.log(.info, "Pipeline", "Identification models loaded")
        } catch {
            log.log(.error, "Pipeline", "Identification model failed: \(error.localizedDescription)")
            logger.error("Identification model failed: \(error)")
        }

        // 3. VLM — skip at startup to avoid iOS disk-write watchdog kill
        // (~3GB download + CoreML compilation exceeds iOS daily write budget).
        // VLM loads lazily on first pipeline run, or manually via Settings.
        log.log(.info, "Pipeline", "VLM deferred (load on first use or via Settings)")

        // Require detector at minimum — without detection, no people found = all photos pass through unfiltered
        isReady = detectorReady
        if detectorReady {
            loadingStatus = vlmService.isLoaded ? "Ready" : "Ready (VLM unavailable)"
        } else {
            loadingStatus = "Error: detection models failed to load"
        }
        log.log(detectorReady ? .info : .error, "Pipeline", "Pipeline \(detectorReady ? "ready" : "NOT ready") (detector: \(detectorReady), enroll: \(isEnrollReady), VLM: \(vlmService.isLoaded))")
    }

    /// Process a single photo through the full pipeline.
    func processPhoto(_ image: CIImage, asset: PHAsset? = nil) async -> PhotoFilterResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let assetID = asset?.localIdentifier.prefix(8) ?? "unknown"
        isProcessing = true
        defer { isProcessing = false }

        CrashGuard.shared.breadcrumb("Pipeline", "processPhoto START [\(assetID)] extent=\(image.extent)")

        // Step 1: Detect people
        let log = LogStore.shared
        let detectedPeople: [DetectedPerson]
        do {
            CrashGuard.shared.breadcrumb("Pipeline", "detect() START [\(assetID)]")
            CrashGuard.shared.flushToDisk()
            detectedPeople = try await detector.detect(in: image)
            CrashGuard.shared.breadcrumb("Pipeline", "detect() OK [\(assetID)] found=\(detectedPeople.count)")
            if !detectedPeople.isEmpty {
                log.log(.info, "Pipeline", "Detected \(detectedPeople.count) person(s)")
            }
        } catch {
            CrashGuard.shared.breadcrumb("Pipeline", "detect() FAILED [\(assetID)] \(error.localizedDescription)")
            logger.error("Detection failed: \(error)")
            log.log(.error, "Pipeline", "Detection failed: \(error.localizedDescription)")
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            return PhotoFilterResult(
                asset: asset, personResults: [],
                overallDecision: .error("Detection failed: \(error.localizedDescription)"),
                processingTimeMs: elapsed
            )
        }

        // No people detected → keep
        guard !detectedPeople.isEmpty else {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            return PhotoFilterResult(asset: asset, personResults: [], overallDecision: .keep, processingTimeMs: elapsed)
        }

        // Step 2-4: Process each detected person
        var personResults: [PersonFilterResult] = []

        for person in detectedPeople {
            let result = await processOnePerson(person, in: image)
            personResults.append(result)
        }

        let overall = Self.overallDecision(for: personResults)

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        return PhotoFilterResult(
            asset: asset, personResults: personResults,
            overallDecision: overall, processingTimeMs: elapsed
        )
    }

    /// Pure function: if ANY person should be hidden or errored, hide the photo.
    static func overallDecision(for personResults: [PersonFilterResult]) -> FilterDecision {
        let shouldHide = personResults.contains {
            if case .hide = $0.decision { return true }
            if case .error = $0.decision { return true }
            return false
        }
        return shouldHide ? .hide : .keep
    }

    private func processOnePerson(_ person: DetectedPerson, in image: CIImage) async -> PersonFilterResult {
        // Step 2: Try to identify
        let log = LogStore.shared
        CrashGuard.shared.breadcrumb("Pipeline", "identify() START src=\(person.source)")
        let idResult: IdentificationResult?
        do {
            idResult = try await identifier.identify(person: person, in: image)
            CrashGuard.shared.breadcrumb("Pipeline", "identify() OK match=\(idResult?.isMatch ?? false)")
        } catch {
            // Fail-closed: identification error → hide (privacy app must not show photos on error)
            CrashGuard.shared.breadcrumb("Pipeline", "identify() FAILED \(error.localizedDescription)")
            logger.error("Identification failed: \(error)")
            log.log(.error, "Pipeline", "Identification failed: \(error.localizedDescription)")
            return PersonFilterResult(
                person: person, identification: nil,
                hairSegResult: nil, modestyAssessment: nil,
                decision: .error("Identification failed: \(error.localizedDescription)"),
                decisionReason: "Identification error — hiding for safety"
            )
        }

        // If not matched to any enrolled person, keep (we only filter enrolled people)
        guard let id = idResult, id.isMatch else {
            return PersonFilterResult(
                person: person, identification: idResult,
                hairSegResult: nil, modestyAssessment: nil,
                decision: .unknown, decisionReason: "Person not enrolled"
            )
        }

        // Check filter mode for this person
        // TODO: Load per-person filter mode from settings
        let filterMode: FilterMode = .defaultFilter

        // Always hide mode
        if filterMode == .alwaysHide {
            return PersonFilterResult(
                person: person, identification: id,
                hairSegResult: nil, modestyAssessment: nil,
                decision: .hide, decisionReason: "Always-hide mode"
            )
        }

        // Step 3: Hair segmentation pre-filter
        CrashGuard.shared.breadcrumb("Pipeline", "hairSeg() START")
        CrashGuard.shared.flushToDisk()
        let hairResult: HairSegmentationResult?
        do {
            hairResult = try await hairSegmenter.analyze(person: person, in: image)
            CrashGuard.shared.breadcrumb("Pipeline", "hairSeg() OK ratio=\(hairResult?.hairRatio ?? 0)")
        } catch {
            CrashGuard.shared.breadcrumb("Pipeline", "hairSeg() FAILED \(error.localizedDescription)")
            logger.warning("Hair segmentation failed: \(error)")
            log.log(.warning, "Pipeline", "Hair seg failed: \(error.localizedDescription)")
            hairResult = nil
        }

        // If hair clearly visible, skip VLM
        if let hr = hairResult, hr.skipVLM {
            return PersonFilterResult(
                person: person, identification: id,
                hairSegResult: hr, modestyAssessment: nil,
                decision: .hide, decisionReason: "Hair visible (ratio: \(String(format: "%.2f", hr.hairRatio)))"
            )
        }

        // Step 4: VLM modesty check — require VLM to be pre-loaded (via Settings).
        // Never lazy-load during scan: 3GB download + compile would spike memory and get killed by iOS.
        guard vlmService.isLoaded else {
            return PersonFilterResult(
                person: person, identification: id,
                hairSegResult: hairResult, modestyAssessment: nil,
                decision: .hide, decisionReason: "VLM not loaded — hiding for safety (download model in Settings)"
            )
        }
        // Prefer instance-masked crop (isolates person), fall back to rectangular personBox crop.
        let personCrop: CIImage
        if #available(iOS 17.0, *), let maskIdx = person.instanceMaskIndex,
           let maskedCrop = try? await detector.maskedCrop(instanceIndex: maskIdx, in: image) {
            personCrop = maskedCrop
        } else {
            let imageSize = image.extent.size
            let personRect = VisionCoordinates.toCIImageRect(person.personBox, imageSize: imageSize)
                .intersection(image.extent)
            personCrop = image.cropped(to: personRect)
        }

        let assessment: ModestyAssessment?
        do {
            let prompt: String? = nil  // TODO: per-person custom prompts
            assessment = try await vlmService.assessModesty(personCrop: personCrop, customPrompt: prompt)
        } catch {
            logger.error("VLM assessment failed: \(error)")
            log.log(.error, "Pipeline", "VLM assessment failed: \(error.localizedDescription)")
            assessment = nil
        }

        let decision: FilterDecision
        let reason: String
        if let a = assessment {
            decision = a.isModest ? .keep : .hide
            reason = "VLM: \(a.isModest ? "modest" : "not modest") (\(a.confidence.rawValue)) — \(a.reason)"
        } else {
            // VLM failure → fail-safe to hide (privacy app)
            decision = .hide
            reason = "VLM unavailable, hiding for safety"
        }

        return PersonFilterResult(
            person: person, identification: id,
            hairSegResult: hairResult, modestyAssessment: assessment,
            decision: decision, decisionReason: reason
        )
    }

    /// Release heavy models (VLM) to free memory.
    func releaseVLM() {
        vlmService.unload()
    }
}
