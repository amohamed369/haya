import Foundation
import Vision
import CoreML
import CoreImage
import UIKit
import os

private let logger = Logger(subsystem: "com.haya.app", category: "PersonDetector")

/// Source of the tight person crop box.
enum PersonBoxSource {
    case mask           // YOLO segmentation mask (tightest — not yet available via Vision framework)
    case faceAnchored   // Estimated from face using anthropometric ratios
    case yoloRaw        // Raw YOLO bounding box
}

/// Result of detecting a person in an image.
struct DetectedPerson: Identifiable {
    let id = UUID()
    /// Bounding box in normalized coordinates (top-left origin, 0-1 range).
    let boundingBox: CGRect
    /// Face observation from Vision, if a face was detected.
    let faceObservation: VNFaceObservation?
    /// Body bounding box from YOLO, if a body was detected.
    let bodyBoundingBox: CGRect?
    /// Tight single-person crop box for embeddings and VLM (normalized, top-left origin).
    let personBox: CGRect
    /// How personBox was derived.
    let personBoxSource: PersonBoxSource
    /// Whether the YOLO body box contains multiple people.
    let isMultiPerson: Bool
    /// Detection confidence (0-1).
    let confidence: Float
    /// Source of detection.
    let source: DetectionSource

    enum DetectionSource {
        case faceOnly
        case bodyOnly
        case faceAndBody
    }
}

/// Detects people in images using Apple Vision (faces) + YOLO11n-seg (bodies).
actor PersonDetector {
    private var yoloModel: VNCoreMLModel?

    func loadModels() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let url = try Self.modelURL(name: "YOLO11nSeg")
        let yolo = try MLModel(contentsOf: url, configuration: config)
        yoloModel = try VNCoreMLModel(for: yolo)
    }

    /// Detect all people (faces + bodies) in the given image.
    func detect(in ciImage: CIImage) async throws -> [DetectedPerson] {
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])

        // Set up face detection request
        let faceRequest = VNDetectFaceLandmarksRequest()
        faceRequest.revision = VNDetectFaceLandmarksRequestRevision3

        // Set up body detection request (YOLO)
        var bodyResults: [(CGRect, Float)] = []
        var requests: [VNRequest] = [faceRequest]

        if let model = yoloModel {
            let bodyRequest = VNCoreMLRequest(model: model) { request, _ in
                guard let observations = request.results as? [VNRecognizedObjectObservation] else { return }
                for obs in observations {
                    let topLabel = obs.labels.first
                    if topLabel?.identifier == "person" || topLabel?.identifier == "0" {
                        let flipped = VisionCoordinates.flipToTopLeft(obs.boundingBox)
                        bodyResults.append((flipped, obs.confidence))
                    }
                }
            }
            bodyRequest.imageCropAndScaleOption = .scaleFill
            requests.append(bodyRequest)
        }

        try handler.perform(requests)

        let faceResults = parseFaceResults(faceRequest)
        return mergeDetections(faces: faceResults, bodies: bodyResults)
    }

    // MARK: - Face Result Parsing

    private func parseFaceResults(_ request: VNDetectFaceLandmarksRequest) -> [(CGRect, VNFaceObservation)] {
        guard let results = request.results else { return [] }
        return results.compactMap { face in
            let flipped = VisionCoordinates.flipToTopLeft(face.boundingBox)
            return (flipped, face)
        }
    }

    // MARK: - Person Box Estimation

    /// Estimate single-person body box from face using anthropometric ratios.
    /// Body width ~ 3.5x face width, body height ~ 7.5x face height.
    /// All coordinates in normalized space (0-1, top-left origin).
    static func estimatePersonBox(faceBox: CGRect, scale: CGFloat = 3.5) -> CGRect {
        let fw = faceBox.width
        let fh = faceBox.height
        let fcx = faceBox.midX

        let bodyW = fw * scale
        let bodyH = fh * 7.5

        let bx1 = max(0, fcx - bodyW / 2)
        let by1 = max(0, faceBox.minY - fh * 0.5)
        let bx2 = min(1.0, fcx + bodyW / 2)
        let by2 = min(1.0, by1 + bodyH)

        return CGRect(x: bx1, y: by1, width: bx2 - bx1, height: by2 - by1)
    }

    // MARK: - Merge Detections

    /// Merge face and body detections with multi-person handling.
    /// For each body box, counts face centroids inside to detect multi-person boxes.
    /// When multi-person, tries face-anchored estimate — uses it if cleaner (fewer faces).
    private func mergeDetections(
        faces: [(CGRect, VNFaceObservation)],
        bodies: [(CGRect, Float)]
    ) -> [DetectedPerson] {
        var results: [DetectedPerson] = []
        var usedFaces: Set<Int> = []

        for (bodyRect, bodyConf) in bodies {
            // Count face centroids inside this body box
            var facesInside: [(index: Int, rect: CGRect, obs: VNFaceObservation)] = []
            for (fi, (faceRect, faceObs)) in faces.enumerated() {
                let centroid = CGPoint(x: faceRect.midX, y: faceRect.midY)
                if bodyRect.contains(centroid) {
                    facesInside.append((fi, faceRect, faceObs))
                }
            }

            var isMultiPerson = facesInside.count > 1

            // Pick best unused face
            var bestFace: (index: Int, rect: CGRect, obs: VNFaceObservation)?
            for entry in facesInside {
                if !usedFaces.contains(entry.index) {
                    bestFace = entry
                    break
                }
            }

            // Compute personBox: when multi-person, try face-anchored estimate
            let personBox: CGRect
            let personBoxSource: PersonBoxSource

            if isMultiPerson, let face = bestFace {
                let estBox = Self.estimatePersonBox(faceBox: face.rect)
                // Check if estimate contains fewer faces
                let estFaceCount = faces.filter { estBox.contains(CGPoint(x: $0.0.midX, y: $0.0.midY)) }.count
                if estFaceCount <= 1 {
                    personBox = estBox
                    personBoxSource = .faceAnchored
                    isMultiPerson = false
                    logger.debug("Face-anchored crop cleaner than YOLO box — using estimate")
                } else {
                    personBox = bodyRect
                    personBoxSource = .yoloRaw
                }
            } else {
                personBox = bodyRect
                personBoxSource = .yoloRaw
            }

            if let face = bestFace {
                usedFaces.insert(face.index)
                let merged = bodyRect.union(face.rect)
                results.append(DetectedPerson(
                    boundingBox: merged,
                    faceObservation: face.obs,
                    bodyBoundingBox: bodyRect,
                    personBox: personBox,
                    personBoxSource: personBoxSource,
                    isMultiPerson: isMultiPerson,
                    confidence: max(face.obs.confidence, bodyConf),
                    source: .faceAndBody
                ))
            } else {
                results.append(DetectedPerson(
                    boundingBox: bodyRect,
                    faceObservation: nil,
                    bodyBoundingBox: bodyRect,
                    personBox: personBox,
                    personBoxSource: personBoxSource,
                    isMultiPerson: isMultiPerson,
                    confidence: bodyConf,
                    source: .bodyOnly
                ))
            }
        }

        // Unmatched faces — estimate body from face
        for (fi, (faceRect, faceObs)) in faces.enumerated() where !usedFaces.contains(fi) {
            let estBox = Self.estimatePersonBox(faceBox: faceRect)
            results.append(DetectedPerson(
                boundingBox: estBox,
                faceObservation: faceObs,
                bodyBoundingBox: nil,
                personBox: estBox,
                personBoxSource: .faceAnchored,
                isMultiPerson: false,
                confidence: faceObs.confidence,
                source: .faceOnly
            ))
        }

        return results
    }

    /// Intersection area over the smaller rect's area.
    private func intersectionOverMinArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let minArea = min(a.width * a.height, b.width * b.height)
        guard minArea > 0 else { return 0 }
        return (intersection.width * intersection.height) / minArea
    }

    // MARK: - Model URL

    private static func modelURL(name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") { return url }
        throw NSError(domain: "com.haya.ml", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model \(name) not found in bundle"])
    }
}
