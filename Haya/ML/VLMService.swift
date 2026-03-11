import Foundation
import CoreImage
import UIKit
import MLX
import MLXLMCommon
import os

private let logger = Logger(subsystem: "com.haya.app", category: "VLMService")

/// VLM-based modesty assessment result.
struct ModestyAssessment {
    let isModest: Bool
    let confidence: String  // "high", "medium", "low"
    let reason: String
    let rawResponse: String
}

/// Qwen2.5-VL modesty assessment via MLX Swift.
/// Creates a fresh ChatSession per assessment to avoid context contamination.
@MainActor
class VLMService {
    private var modelContext: ModelContext?
    private let ciContext = CIContext()
    private var _isLoading = false

    /// Model ID — Qwen2.5-VL-3B (83% accuracy in Kaggle testing, natively supported in mlx-swift-lm).
    let modelID = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"

    init() {}

    /// Load the VLM model. Downloads from HuggingFace on first launch.
    func loadModel() async throws {
        guard modelContext == nil, !_isLoading else { return }
        _isLoading = true
        defer { _isLoading = false }

        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

        let loaded = try await MLXLMCommon.loadModel(id: modelID)
        self.modelContext = loaded
    }

    /// Assess whether a person in the image is modestly dressed.
    /// Creates a fresh ChatSession per call — no context leaks between photos.
    func assessModesty(personCrop: CIImage, customPrompt: String? = nil) async throws -> ModestyAssessment {
        guard let context = modelContext else {
            throw VLMError.modelNotLoaded
        }

        // Fresh session per assessment — no context leaks between photos.
        let session = ChatSession(
            context,
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
        modelContext = nil
        MLX.GPU.set(cacheLimit: 0)
    }

    var isLoaded: Bool { modelContext != nil }
    var currentModelID: String { modelID }

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
        let confidence: String
        if upper.contains("HIGH") {
            confidence = "high"
        } else if upper.contains("LOW") {
            confidence = "low"
        } else {
            confidence = "medium"
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

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "VLM model not loaded. Call loadModel() first."
            case .imageConversionFailed: return "Failed to convert image for VLM processing."
            }
        }
    }
}
