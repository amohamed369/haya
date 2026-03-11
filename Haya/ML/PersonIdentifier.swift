import Foundation
import CoreML
import CoreImage
import Vision
import os

private let logger = Logger(subsystem: "com.haya.app", category: "PersonIdentifier")

/// Stored enrollment for a known person.
struct PersonEnrollment: Codable, Identifiable {
    let id: String
    let name: String
    private(set) var faceCentroid: [Float]?
    private(set) var bodyCentroid: [Float]?
    let faceEmbeddingCount: Int
    let bodyEmbeddingCount: Int
}

/// Result of identifying a detected person against enrolled people.
struct IdentificationResult {
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
        config.computeUnits = .all

        arcFaceModel = try MLModel(contentsOf: Self.modelURL(name: "ArcFace"), configuration: config)
        clipreidModel = try MLModel(contentsOf: Self.modelURL(name: "CLIPReID"), configuration: config)

        enrollments = Self.loadEnrollments()
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

    func enroll(name: String, images: [CIImage]) async throws -> PersonEnrollment {
        var faceEmbeddings: [[Float]] = []
        var bodyEmbeddings: [[Float]] = []

        for image in images {
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            let faceRequest = VNDetectFaceLandmarksRequest()
            try handler.perform([faceRequest])

            if let face = faceRequest.results?.first,
               let aligned = FaceAligner.alignFace(from: image, face: face),
               let emb = try extractFaceEmbedding(alignedFace: aligned) {
                faceEmbeddings.append(emb)
            }

            if let emb = try extractBodyEmbedding(bodyCrop: image) {
                bodyEmbeddings.append(emb)
            }
        }

        let enrollment = PersonEnrollment(
            id: UUID().uuidString,
            name: name,
            faceCentroid: EmbeddingMath.computeCentroid(faceEmbeddings),
            bodyCentroid: EmbeddingMath.computeCentroid(bodyEmbeddings),
            faceEmbeddingCount: faceEmbeddings.count,
            bodyEmbeddingCount: bodyEmbeddings.count
        )

        enrollments.append(enrollment)
        try Self.saveEnrollments(enrollments)
        return enrollment
    }

    func removeEnrollment(id: String) throws {
        enrollments.removeAll { $0.id == id }
        try Self.saveEnrollments(enrollments)
    }

    var currentEnrollments: [PersonEnrollment] { enrollments }

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
        do {
            let data = try Data(contentsOf: enrollmentsFile)
            return try JSONDecoder().decode([PersonEnrollment].self, from: data)
        } catch {
            logger.info("No existing enrollments (or decode error): \(error)")
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
