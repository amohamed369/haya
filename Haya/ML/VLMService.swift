import Foundation
import CoreImage
import UIKit
import MLX
import MLXVLM
import MLXLMCommon
import os

private let logger = Logger(subsystem: "com.haya.app", category: "VLMService")

/// VLM-based modesty assessment result.
struct ModestyAssessment: Sendable {
    enum ConfidenceLevel: String, Sendable {
        case high, medium, low
    }

    let isModest: Bool
    let confidence: ConfidenceLevel
    let reason: String
    let rawResponse: String
}

/// Qwen2.5-VL modesty assessment via MLX Swift.
/// Creates a fresh ChatSession per assessment to avoid context contamination.
@MainActor
class VLMService: ObservableObject {
    private var modelContainer: ModelContainer?
    private let ciContext = CIContext()

    /// Model ID — Qwen3.5-4B (MMMU 77.6, native multimodal, natively supported in mlx-swift-lm).
    let modelID = "mlx-community/Qwen3.5-4B-MLX-4bit"

    /// Estimated model size in bytes (~3.03 GB for 4B 4-bit).
    static let estimatedModelSizeBytes: Int64 = 3_030_000_000

    /// Download / load state machine.
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case error(String)
    }

    @Published private(set) var downloadState: DownloadState = .notDownloaded

    /// Computed from downloadState — no duplicate state.
    var downloadProgress: Double {
        if case .downloading(let p) = downloadState { return p }
        return downloadState == .ready ? 1.0 : 0.0
    }

    init() {}

    /// Download and load the VLM model with progress tracking.
    func downloadAndLoad() async {
        // Only allow starting from notDownloaded or error states
        switch downloadState {
        case .notDownloaded, .error: break
        case .downloading, .ready: return
        }

        // Disk space check: need ~3x model size (download + compile + overhead)
        let requiredSpace = Self.estimatedModelSizeBytes * 3
        if !Self.hasAvailableDiskSpace(requiredSpace) {
            let needed = ByteCountFormatter.string(fromByteCount: requiredSpace, countStyle: .file)
            downloadState = .error("Not enough disk space. Need \(needed) free.")
            LogStore.shared.log(.error, "VLM", "Insufficient disk space for model download")
            return
        }

        downloadState = .downloading(progress: 0)
        LogStore.shared.log(.info, "VLM", "Downloading \(modelID)...")

        do {
            MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

            let config = ModelConfiguration(id: modelID)
            let container = try await VLMModelFactory.shared.loadContainer(
                configuration: config
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadState = .downloading(progress: progress.fractionCompleted)
                }
            }

            self.modelContainer = container
            downloadState = .ready
            LogStore.shared.log(.info, "VLM", "Model downloaded and loaded successfully")
        } catch {
            downloadState = .error(error.localizedDescription)
            LogStore.shared.log(.error, "VLM", "Download failed: \(error.localizedDescription)")
            logger.error("VLM download failed: \(error)")
        }
    }

    /// Load a previously downloaded model (no download needed).
    func loadModel() async throws {
        // If already loaded, skip
        guard modelContainer == nil else { return }

        // If download hasn't happened, use downloadAndLoad instead
        await downloadAndLoad()
        if modelContainer == nil {
            throw VLMError.modelNotLoaded
        }
    }

    /// Assess whether a person in the image is modestly dressed.
    /// Creates a fresh ChatSession per call — no context leaks between photos.
    func assessModesty(personCrop: CIImage, customPrompt: String? = nil) async throws -> ModestyAssessment {
        guard let container = modelContainer else {
            throw VLMError.modelNotLoaded
        }

        // Fresh session per assessment — no context leaks between photos.
        let session = ChatSession(
            container,
            instructions: "You check Islamic modesty in photos. Focus ONLY on THIS person. Be extremely concise.",
            generateParameters: GenerateParameters(maxTokens: 200),
            processing: UserInput.Processing(resize: CGSize(width: 448, height: 448))
        )

        let tempURL = try saveToTempFile(personCrop)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let prompt = customPrompt ?? Self.defaultModestyPrompt

        let responseText = try await session.respond(
            to: prompt,
            image: UserInput.Image.url(tempURL)
        )

        return parseModestyResponse(responseText)
    }

    /// Release the model to free memory.
    func unload() {
        modelContainer = nil
        MLX.GPU.set(cacheLimit: 0)
        downloadState = .notDownloaded
    }

    var isLoaded: Bool { modelContainer != nil }
    var currentModelID: String { modelID }

    /// Formatted model size for display.
    static var formattedModelSize: String {
        ByteCountFormatter.string(fromByteCount: estimatedModelSizeBytes, countStyle: .file)
    }

    /// Check available disk space.
    static func hasAvailableDiskSpace(_ required: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return true // Can't check → allow attempt
        }
        return free > required
    }

    /// Available disk space formatted for display.
    static var availableDiskSpace: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    // MARK: - Prompt

    static let defaultModestyPrompt = """
    Check this person for Islamic modesty. Describe what you see for each area, then judge:

    HEAD/HAIR: [2-3 words] → covered?
    NECK: [2-3 words] → covered?
    ARMS: [2-3 words] → covered to wrists?
    CHEST/TORSO: [2-3 words] → loose, not form-fitting?
    LEGS: [2-3 words] → covered?
    FIT: [2-3 words] → loose overall?

    SELF-CHECK: Re-read your area descriptions. Any bare skin or hair visible?

    VERDICT: YES (all covered) or NO (any bare skin/hair visible)
    """

    // MARK: - Response Parsing

    func parseModestyResponse(_ text: String) -> ModestyAssessment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Scan LAST LINE only for YES/NO verdict (avoids stray "no" in reasoning text).
        // Matches Kaggle _parse_verdict behavior.
        let lastLine = (lines.last ?? trimmed).uppercased()
        let lastLineWords = lastLine.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let verdictWord = lastLineWords.first(where: {
            let clean = $0.trimmingCharacters(in: .punctuationCharacters)
            return clean == "YES" || clean == "NO"
        })?.trimmingCharacters(in: .punctuationCharacters)

        let isModest: Bool
        if let verdict = verdictWord {
            isModest = verdict == "YES"
        } else {
            // Fallback: scan entire response for verdict keywords
            let upper = trimmed.uppercased()
            let modestKeywords = ["MODEST", "COVERED", "HIJAB", "ALL PASS"]
            let immodestKeywords = ["EXPOSED", "REVEALING", "VISIBLE HAIR", "NOT MODEST", "BARE SKIN"]
            let modestScore = modestKeywords.filter { upper.contains($0) }.count
            let immodestScore = immodestKeywords.filter { upper.contains($0) }.count
            // Default to hide (conservative for privacy app)
            isModest = modestScore > immodestScore && immodestScore == 0
        }

        // Extract confidence from response
        let upper = trimmed.uppercased()
        let confidence: ModestyAssessment.ConfidenceLevel
        if upper.contains("HIGH") {
            confidence = .high
        } else if upper.contains("LOW") {
            confidence = .low
        } else {
            confidence = .medium
        }

        let reason = lines.last ?? trimmed

        return ModestyAssessment(
            isModest: isModest,
            confidence: confidence,
            reason: reason,
            rawResponse: text
        )
    }

    // MARK: - Image Helpers

    private func saveToTempFile(_ ciImage: CIImage) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
        guard let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw VLMError.imageConversionFailed
        }
        try ciContext.writeJPEGRepresentation(of: ciImage, to: url, colorSpace: colorSpace, options: [:])
        return url
    }

    enum VLMError: LocalizedError {
        case modelNotLoaded
        case imageConversionFailed
        case insufficientDiskSpace

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "VLM model not loaded. Download it from Settings."
            case .imageConversionFailed: return "Failed to convert image for VLM processing."
            case .insufficientDiskSpace: return "Not enough disk space to download the model."
            }
        }
    }
}
