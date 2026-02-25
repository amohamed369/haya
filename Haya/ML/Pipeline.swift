import Foundation
import CoreImage
import Photos
import os

private let logger = Logger(subsystem: "com.haya.app", category: "Pipeline")

/// Per-person filter mode.
enum FilterMode: String, Codable, CaseIterable {
    case defaultFilter = "default"   // Hair seg + VLM check
    case alwaysHide = "always_hide"  // Always hide this person
    case custom = "custom"           // Custom VLM prompt per person
}

/// Result of processing a single detected person through the pipeline.
struct PersonFilterResult: Identifiable {
    let id = UUID()
    let person: DetectedPerson
    let identification: IdentificationResult?
    let hairSegResult: HairSegmentationResult?
    let modestyAssessment: ModestyAssessment?
    let decision: FilterDecision
    let decisionReason: String
}

enum FilterDecision {
    case keep           // Show the photo
    case hide           // Hide the photo
    case unknown        // Could not determine (no enrolled person matched)
    case error(String)  // Pipeline error — fail-safe to hide
}

/// Full result of processing a photo through the pipeline.
struct PhotoFilterResult {
    let asset: PHAsset?
    let personResults: [PersonFilterResult]
    let overallDecision: FilterDecision
    let processingTimeMs: Int
}

/// Orchestrates the full ML pipeline: Detect → Identify → Filter.
@MainActor
class Pipeline: ObservableObject {
    let detector = PersonDetector()
    let identifier = PersonIdentifier()
    let hairSegmenter = HairSegmenter()
    let vlmService = VLMService()

    @Published var isReady = false
    @Published var isProcessing = false
    @Published var loadingStatus = "Not loaded"
    @Published var vlmLoadingProgress: Double = 0

    /// Load all models. Call once at app startup.
    func loadModels() async {
        loadingStatus = "Loading detection models..."

        do {
            try await detector.loadModels()
            loadingStatus = "Loading identification models..."

            try await identifier.loadModels()
            loadingStatus = "Loading VLM (this may download ~500MB)..."

            try await vlmService.loadModel()

            loadingStatus = "Ready"
            isReady = true
        } catch {
            loadingStatus = "Error: \(error.localizedDescription)"
            logger.error("Failed to load models: \(error)")
        }
    }

    /// Process a single photo through the full pipeline.
    func processPhoto(_ image: CIImage, asset: PHAsset? = nil) async -> PhotoFilterResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        isProcessing = true
        defer { isProcessing = false }

        // Step 1: Detect people
        let detectedPeople: [DetectedPerson]
        do {
            detectedPeople = try await detector.detect(in: image)
        } catch {
            // Detection error is privacy-critical — fail-safe to error (not .keep)
            logger.error("Detection failed: \(error)")
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

        // Overall decision: if ANY person should be hidden or errored, hide the photo
        let shouldHide = personResults.contains {
            if case .hide = $0.decision { return true }
            if case .error = $0.decision { return true }
            return false
        }
        let overall: FilterDecision = shouldHide ? .hide : .keep

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        return PhotoFilterResult(
            asset: asset, personResults: personResults,
            overallDecision: overall, processingTimeMs: elapsed
        )
    }

    private func processOnePerson(_ person: DetectedPerson, in image: CIImage) async -> PersonFilterResult {
        // Step 2: Try to identify
        let idResult: IdentificationResult?
        do {
            idResult = try await identifier.identify(person: person, in: image)
        } catch {
            logger.warning("Identification failed: \(error)")
            idResult = nil
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
        let hairResult: HairSegmentationResult?
        do {
            hairResult = try await hairSegmenter.analyze(person: person, in: image)
        } catch {
            logger.warning("Hair segmentation failed: \(error)")
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

        // Step 4: VLM modesty check — use personBox (tight single-person crop)
        let imageSize = image.extent.size
        let personRect = VisionCoordinates.toCIImageRect(person.personBox, imageSize: imageSize)
            .intersection(image.extent)

        let personCrop = image.cropped(to: personRect)

        let assessment: ModestyAssessment?
        do {
            let prompt: String? = nil  // TODO: per-person custom prompts
            assessment = try await vlmService.assessModesty(personCrop: personCrop, customPrompt: prompt)
        } catch {
            logger.error("VLM assessment failed: \(error)")
            assessment = nil
        }

        let decision: FilterDecision
        let reason: String
        if let a = assessment {
            decision = a.isModest ? .keep : .hide
            reason = "VLM: \(a.isModest ? "modest" : "not modest") (\(a.confidence)) — \(a.reason)"
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
