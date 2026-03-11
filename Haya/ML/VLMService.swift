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

/// SmolVLM2 service for modesty assessment via MLX Swift.
/// Creates a fresh ChatSession per assessment to avoid context contamination.
@MainActor
class VLMService {
    private var modelContainer: ModelContainer?
    private let ciContext = CIContext()
    private var _isLoading = false

    /// Model ID — auto-selected by available RAM.
    let modelID: String

    init() {
        let availableBytes = os_proc_available_memory()
        let availableMB = availableBytes / (1024 * 1024)
        if availableMB > 3000 {
            modelID = "mlx-community/SmolVLM2-2.2B-Instruct-4bit"
        } else {
            modelID = "mlx-community/SmolVLM2-256M-Instruct-4bit"
        }
    }

    /// Load the VLM model. Downloads from HuggingFace on first launch.
    func loadModel() async throws {
        guard modelContainer == nil, !_isLoading else { return }
        _isLoading = true
        defer { _isLoading = false }

        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

        let loaded = try await MLXLMCommon.loadModel(id: modelID)
        self.modelContainer = loaded
    }

    /// Assess whether a person in the image is modestly dressed.
    /// Creates a fresh ChatSession per call — no context leaks between photos.
    func assessModesty(personCrop: CIImage, customPrompt: String? = nil) async throws -> ModestyAssessment {
        guard let container = modelContainer else {
            throw VLMError.modelNotLoaded
        }

        // Fresh session per assessment — Context7 confirms this is the idiomatic pattern:
        // "If you need a one-shot prompt/response simply create a ChatSession, evaluate the prompt and discard."
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 60),
            processing: UserInput.Processing(resize: CGSize(width: 384, height: 384))
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
    }

    var isLoaded: Bool { modelContainer != nil }
    var currentModelID: String { modelID }

    // MARK: - Prompt

    static let defaultModestyPrompt = """
    Evaluate this person for modesty. Default answer is NO.

    Check each — if ANY fails, answer NO:
    [ ] Hair mostly covered (hijab, scarf, beanie, hoodie) — a few wisps or strands at edges are OK, but significant visible hair = FAIL
    [ ] Arms covered to wrists — bare upper arms or sleeveless = FAIL
    [ ] Legs covered (long pants or skirt) — any bare legs = FAIL
    [ ] Clothing loose, not tight — form-fitting = FAIL

    If ANY check FAIL: answer NO
    Only if ALL checks pass: answer YES

    Format: YES or NO, confidence (high/medium/low), which check failed or "all pass"
    """

    // MARK: - Response Parsing

    func parseModestyResponse(_ text: String) -> ModestyAssessment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        // Scan first 5 words for YES/NO (handles VLM preamble like "Based on the image, YES...")
        // Strip punctuation so "YES," / "YES." matches "YES" (avoids "NOBODY"/"NONE" false positives)
        let words = upper.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let answerWord = words.prefix(5).first(where: {
            let clean = $0.trimmingCharacters(in: .punctuationCharacters)
            return clean == "YES" || clean == "NO"
        })?.trimmingCharacters(in: .punctuationCharacters)

        let isModest: Bool
        if answerWord == "YES" {
            isModest = true
        } else if answerWord == "NO" {
            isModest = false
        } else {
            // Fallback: keyword scoring
            let modestKeywords = ["modest", "covered", "hijab", "appropriate"]
            let immodestKeywords = ["exposed", "revealing", "visible hair", "not modest", "immodest"]
            let modestScore = modestKeywords.filter { upper.contains($0.uppercased()) }.count
            let immodestScore = immodestKeywords.filter { upper.contains($0.uppercased()) }.count
            isModest = modestScore > immodestScore
        }

        let confidence: String
        if upper.contains("HIGH") {
            confidence = "high"
        } else if upper.contains("LOW") {
            confidence = "low"
        } else {
            confidence = "medium"
        }

        let reason = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .last ?? text

        return ModestyAssessment(
            isModest: isModest,
            confidence: confidence,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
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
