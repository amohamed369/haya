import Foundation
import CoreML
import CoreImage
import Vision
import os

private let logger = Logger(subsystem: "com.haya.app", category: "PersonIdentifier")

/// Stored enrollment for a known person.
struct PersonEnrollment: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    private(set) var faceCentroid: [Float]?
    private(set) var bodyCentroid: [Float]?
    let faceEmbeddingCount: Int
    let bodyEmbeddingCount: Int
}

/// Result of identifying a detected person against enrolled people.
struct IdentificationResult: Sendable {
    let enrollmentID: String?
    let name: String?
    let faceSimilarity: Float?
    let bodySimilarity: Float?
    let isMatch: Bool
}

/// Identifies people using ArcFace (face embeddings) + CLIP-ReID (body embeddings).
actor PersonIdentifier {
    private var arcFaceModel: MLModel?
    private var clipreidModel: MLModel?
    private var enrollments: [PersonEnrollment] = []
    private let ciContext = CIContext()

    static let faceThreshold: Float = 0.35
    static let bodyThreshold: Float = 0.80
    static let bodyWithWrongFaceThreshold: Float = 0.90

    func loadModels() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU // ANE compiler crashes on iOS 26.3 beta
        CrashGuard.shared.breadcrumb("Identifier", "loadModels() START")
        CrashGuard.shared.flushToDisk()

        // Load each model independently — one failure shouldn't block the other
        do {
            CrashGuard.shared.breadcrumb("Identifier", "ArcFace loading...")
            arcFaceModel = try MLModel(contentsOf: Self.modelURL(name: "ArcFace"), configuration: config)
            CrashGuard.shared.breadcrumb("Identifier", "ArcFace OK")
            await LogStore.shared.log(.info, "Identifier", "ArcFace loaded")
        } catch {
            CrashGuard.shared.breadcrumb("Identifier", "ArcFace FAILED: \(error.localizedDescription)")
            await LogStore.shared.log(.error, "Identifier", "ArcFace failed: \(error.localizedDescription)")
            logger.error("ArcFace failed: \(error)")
        }

        do {
            CrashGuard.shared.breadcrumb("Identifier", "CLIPReID loading...")
            CrashGuard.shared.flushToDisk()
            clipreidModel = try MLModel(contentsOf: Self.modelURL(name: "CLIPReID"), configuration: config)
            CrashGuard.shared.breadcrumb("Identifier", "CLIPReID OK")
            await LogStore.shared.log(.info, "Identifier", "CLIPReID loaded")
        } catch {
            CrashGuard.shared.breadcrumb("Identifier", "CLIPReID FAILED: \(error.localizedDescription)")
            await LogStore.shared.log(.error, "Identifier", "CLIPReID failed: \(error.localizedDescription)")
            logger.error("CLIPReID failed: \(error)")
        }

        if arcFaceModel == nil && clipreidModel == nil {
            throw NSError(domain: "com.haya.ml", code: -1, userInfo: [NSLocalizedDescriptionKey: "No identification models loaded"])
        }

        enrollments = Self.loadEnrollments()
        CrashGuard.shared.breadcrumb("Identifier", "Enrollments loaded: \(enrollments.count)")
        await LogStore.shared.log(.info, "Identifier", "Loaded \(enrollments.count) enrollment(s)")
    }

    // MARK: - Embedding Extraction

    func extractFaceEmbedding(alignedFace: CIImage) throws -> [Float]? {
        guard let model = arcFaceModel else { return nil }

        guard let cgImage = ciContext.createCGImage(alignedFace, from: alignedFace.extent) else { return nil }
        let pixelBuffer = try createPixelBuffer(from: cgImage, width: 112, height: 112)

        let input = try MLDictionaryFeatureProvider(dictionary: ["face_image": MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)

        return extractFloatArray(from: output)
    }

    func extractBodyEmbedding(bodyCrop: CIImage) throws -> [Float]? {
        guard let model = clipreidModel else { return nil }

        guard let cgImage = ciContext.createCGImage(bodyCrop, from: bodyCrop.extent) else { return nil }
        let pixelBuffer = try createPixelBuffer(from: cgImage, width: 128, height: 256)

        let input = try MLDictionaryFeatureProvider(dictionary: ["body_image": MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)

        return extractFloatArray(from: output)
    }

    // MARK: - Identification

    func identify(person: DetectedPerson, in image: CIImage) throws -> IdentificationResult {
        let imageSize = image.extent.size
        var faceSim: Float?
        var bodySim: Float?
        var bestFaceMatch: (id: String, similarity: Float)?
        var bestBodyMatch: (id: String, similarity: Float)?

        // Face embedding path
        if let faceObs = person.faceObservation,
           let aligned = FaceAligner.alignFace(from: image, face: faceObs),
           var embedding = try extractFaceEmbedding(alignedFace: aligned) {
            EmbeddingMath.l2Normalize(&embedding)
            let centroids = centroidsFor(\.faceCentroid)
            bestFaceMatch = EmbeddingMath.bestMatch(query: embedding, centroids: centroids)
            faceSim = bestFaceMatch?.similarity
        }

        // Body embedding path — use personBox (tight single-person crop)
        let bodyRect = VisionCoordinates.toCIImageRect(person.personBox, imageSize: imageSize)
        let bodyCrop = image.cropped(to: bodyRect)
        if var embedding = try extractBodyEmbedding(bodyCrop: bodyCrop) {
            EmbeddingMath.l2Normalize(&embedding)
            let centroids = centroidsFor(\.bodyCentroid)
            bestBodyMatch = EmbeddingMath.bestMatch(query: embedding, centroids: centroids)
            bodySim = bestBodyMatch?.similarity
        }

        // Face-primary matching (matches Python cell9.py logic)
        let fs = faceSim ?? 0
        let bs = bodySim ?? 0
        let hasFace = person.faceObservation != nil

        let matched: Bool
        var matchID: String?

        if fs >= Self.faceThreshold {
            // Strong face match — authoritative (biometric)
            matched = true
            matchID = bestFaceMatch?.id
        } else if hasFace && fs > 0 && fs < Self.faceThreshold && bs >= Self.bodyWithWrongFaceThreshold {
            // Face detected but doesn't match — require very high body score to override
            matched = true
            matchID = bestBodyMatch?.id
        } else if bs >= Self.bodyThreshold {
            // No face detected — trust body alone
            matched = true
            matchID = bestBodyMatch?.id
        } else {
            matched = false
        }

        if matched, let id = matchID {
            let name = enrollments.first(where: { $0.id == id })?.name
            return IdentificationResult(
                enrollmentID: id, name: name,
                faceSimilarity: faceSim, bodySimilarity: bodySim,
                isMatch: true
            )
        }

        return IdentificationResult(
            enrollmentID: nil, name: nil,
            faceSimilarity: faceSim, bodySimilarity: bodySim,
            isMatch: false
        )
    }

    // MARK: - Enrollment

    /// Enroll a person with optional per-image face selections.
    /// - Parameters:
    ///   - faceSelections: Normalized face rects (Vision bottom-left origin) per image.
    ///     nil array = auto-pick first face. nil element = auto-pick for that image.
    func enroll(name: String, images: [CIImage], faceSelections: [CGRect?]? = nil) async throws -> PersonEnrollment {
        var faceEmbeddings: [[Float]] = []
        var bodyEmbeddings: [[Float]] = []

        for (i, image) in images.enumerated() {
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            let faceRequest = VNDetectFaceLandmarksRequest()
            try handler.perform([faceRequest])

            let selectedRect: CGRect? = {
                guard let selections = faceSelections, i < selections.count else { return nil }
                return selections[i]
            }()

            // Pick the correct face observation
            let face: VNFaceObservation? = {
                guard let results = faceRequest.results, !results.isEmpty else { return nil }
                if let sel = selectedRect {
                    // Find the face observation closest to the selected rect
                    return results.min(by: { a, b in
                        rectDistance(a.boundingBox, sel) < rectDistance(b.boundingBox, sel)
                    })
                }
                return results.first
            }()

            if let face,
               let aligned = FaceAligner.alignFace(from: image, face: face),
               let emb = try extractFaceEmbedding(alignedFace: aligned) {
                faceEmbeddings.append(emb)
            }

            // Body crop: use face-anchored estimate if we have a face, else full image
            let bodyCrop: CIImage
            if let face {
                let faceBox = VisionCoordinates.flipToTopLeft(face.boundingBox)
                let personBox = PersonDetector.estimatePersonBox(faceBox: faceBox)
                let imageSize = image.extent.size
                let cropRect = VisionCoordinates.toCIImageRect(personBox, imageSize: imageSize)
                bodyCrop = image.cropped(to: cropRect)
            } else {
                bodyCrop = image
            }

            if let emb = try extractBodyEmbedding(bodyCrop: bodyCrop) {
                bodyEmbeddings.append(emb)
            }
        }

        let faceCentroid = EmbeddingMath.computeCentroid(faceEmbeddings)
        let bodyCentroid = EmbeddingMath.computeCentroid(bodyEmbeddings)

        // At least one centroid required — without embeddings, matching will always fail silently
        if faceCentroid == nil && bodyCentroid == nil {
            throw NSError(domain: "com.haya.ml", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No faces or bodies could be extracted from the provided photos. Try different photos with clearer faces."
            ])
        }

        let enrollment = PersonEnrollment(
            id: UUID().uuidString,
            name: name,
            faceCentroid: faceCentroid,
            bodyCentroid: bodyCentroid,
            faceEmbeddingCount: faceEmbeddings.count,
            bodyEmbeddingCount: bodyEmbeddings.count
        )

        enrollments.append(enrollment)
        try Self.saveEnrollments(enrollments)
        await LogStore.shared.log(.info, "Identifier", "Enrolled '\(name)' — \(faceEmbeddings.count) face, \(bodyEmbeddings.count) body embeddings")
        return enrollment
    }

    /// Distance between two rects (center-to-center).
    private func rectDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy
    }

    func removeEnrollment(id: String) throws {
        enrollments.removeAll { $0.id == id }
        try Self.saveEnrollments(enrollments)
    }

    var currentEnrollments: [PersonEnrollment] { enrollments }

    // MARK: - Matching Logic (Pure)

    /// Pure matching logic — testable without models.
    struct MatchResult: Sendable {
        let matched: Bool
        let useFace: Bool
        let source: String
    }

    static func matchPerson(faceSimilarity: Float?, bodySimilarity: Float?, hasFace: Bool) -> MatchResult {
        let fs = faceSimilarity ?? 0
        let bs = bodySimilarity ?? 0

        if fs >= faceThreshold {
            return MatchResult(matched: true, useFace: true, source: "face")
        } else if hasFace && fs > 0 && fs < faceThreshold && bs >= bodyWithWrongFaceThreshold {
            return MatchResult(matched: true, useFace: false, source: "body_override")
        } else if bs >= bodyThreshold {
            return MatchResult(matched: true, useFace: false, source: "body")
        } else {
            return MatchResult(matched: false, useFace: false, source: "none")
        }
    }

    // MARK: - Helpers

    private func centroidsFor(_ keyPath: KeyPath<PersonEnrollment, [Float]?>) -> [(id: String, embedding: [Float])] {
        enrollments.compactMap { e in
            guard let c = e[keyPath: keyPath] else { return nil }
            return (e.id, c)
        }
    }

    private func createPixelBuffer(from cgImage: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "com.haya.ml", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }

    private func extractFloatArray(from output: MLFeatureProvider) -> [Float]? {
        for name in output.featureNames {
            if let multiArray = output.featureValue(for: name)?.multiArrayValue {
                let count = multiArray.count
                var result = [Float](repeating: 0, count: count)
                let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
                for i in 0..<count { result[i] = ptr[i] }
                return result
            }
        }
        return nil
    }

    // MARK: - Persistence

    private static let enrollmentsFile: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("haya_enrollments.json")
    }()

    private static func loadEnrollments() -> [PersonEnrollment] {
        guard FileManager.default.fileExists(atPath: enrollmentsFile.path) else {
            logger.info("No enrollments file — first launch")
            return []
        }
        do {
            let data = try Data(contentsOf: enrollmentsFile)
            return try JSONDecoder().decode([PersonEnrollment].self, from: data)
        } catch {
            // File exists but decode failed — data corruption, not first launch
            logger.error("Enrollment file corrupted: \(error)")
            Task { @MainActor in
                LogStore.shared.log(.error, "Identifier", "Enrollment data corrupted — enrollments lost. Re-enroll people in Settings.")
            }
            return []
        }
    }

    private static func saveEnrollments(_ enrollments: [PersonEnrollment]) throws {
        let data = try JSONEncoder().encode(enrollments)
        try data.write(to: enrollmentsFile, options: .atomic)
    }

    // MARK: - Model URLs

    private static func modelURL(name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") { return url }
        throw NSError(domain: "com.haya.ml", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model \(name) not found in bundle"])
    }
}
