import Foundation
import Vision
import CoreML
import CoreImage
import UIKit
import os

private let logger = Logger(subsystem: "com.haya.app", category: "PersonDetector")

/// Source of the tight person crop box.
enum PersonBoxSource: Sendable {
    case instanceMask   // VNGeneratePersonInstanceMaskRequest (tightest, pixel-perfect, iOS 17+)
    case faceAnchored   // Estimated from face using anthropometric ratios
    case yoloRaw        // Raw YOLO bounding box
}

/// Result of detecting a person in an image.
struct DetectedPerson: Identifiable, @unchecked Sendable {
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
    /// Instance mask index for VNGeneratePersonInstanceMaskRequest (iOS 17+).
    /// Use with `PersonDetector.maskedCrop(instanceIndex:)` for pixel-perfect crops.
    let instanceMaskIndex: Int?

    enum DetectionSource {
        case faceOnly
        case bodyOnly
        case faceAndBody
    }
}

/// Detects people in images using Apple Vision (faces) + YOLO11n (bodies) + instance masks (iOS 17+).
/// On iOS 26.3 beta, uses direct MLModel.prediction() for YOLO (Vision framework's ANE path is broken).
actor PersonDetector {
    // Pre-iOS 26: Vision-wrapped model
    private var yoloVisionModel: VNCoreMLModel?
    // iOS 26+: Direct MLModel for YOLO (bypasses Vision's broken ANE path)
    private var yoloDirectModel: MLModel?
    private var yoloOutputName: String?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let isIOS26 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26

    // Instance mask state — kept alive for generating masked crops after detection.
    private var lastMaskObservation: VNInstanceMaskObservation?
    private var lastHandler: VNImageRequestHandler?

    func loadModels() async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU // ANE compiler crashes on iOS 26.3 beta
        CrashGuard.shared.breadcrumb("Detector", "loadModels() START cpuAndGPU iOS26=\(isIOS26)")
        CrashGuard.shared.flushToDisk()
        do {
            let url = try Self.modelURL(name: "YOLO11n")
            CrashGuard.shared.breadcrumb("Detector", "YOLO11n URL=\(url.lastPathComponent)")
            let yolo = try MLModel(contentsOf: url, configuration: config)
            CrashGuard.shared.breadcrumb("Detector", "YOLO11n MLModel OK")

            if isIOS26 {
                // iOS 26: store raw MLModel for direct prediction (bypass Vision)
                yoloDirectModel = yolo
                // Discover output tensor name (varies per export: var_914, var_860, etc.)
                yoloOutputName = yolo.modelDescription.outputDescriptionsByName.keys.first
                CrashGuard.shared.breadcrumb("Detector", "YOLO11n direct mode, output=\(yoloOutputName ?? "nil")")
            } else {
                // Pre-iOS 26: wrap in VNCoreMLModel for Vision pipeline
                yoloVisionModel = try VNCoreMLModel(for: yolo)
                CrashGuard.shared.breadcrumb("Detector", "YOLO11n VNCoreMLModel OK")
            }
            await LogStore.shared.log(.info, "Detector", "YOLO11n loaded (\(isIOS26 ? "direct" : "vision"))")
        } catch {
            CrashGuard.shared.breadcrumb("Detector", "YOLO11n FAILED: \(error.localizedDescription)")
            await LogStore.shared.log(.error, "Detector", "YOLO11n failed: \(error.localizedDescription)")
            logger.error("YOLO11n failed: \(error)")
        }
    }

    /// Generate a pixel-perfect masked crop for a detected person (iOS 17+).
    /// Masks out background and other people, cropped tight to this person.
    @available(iOS 17.0, *)
    func maskedCrop(instanceIndex: Int, in ciImage: CIImage) throws -> CIImage? {
        guard let obs = lastMaskObservation, let handler = lastHandler else { return nil }
        let maskedBuffer = try obs.generateMaskedImage(
            ofInstances: IndexSet(integer: instanceIndex),
            from: handler,
            croppedToInstancesExtent: true
        )
        return CIImage(cvPixelBuffer: maskedBuffer)
    }

    /// Detect all people (faces + bodies + instance masks) in the given image.
    func detect(in ciImage: CIImage) async throws -> [DetectedPerson] {
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let iosVersion = ProcessInfo.processInfo.operatingSystemVersion
        let isIOS26 = iosVersion.majorVersion >= 26

        // iOS 26.3 beta: Vision framework is severely broken:
        //   - VNDetectFaceLandmarksRequest + usesCPUOnly → missing _nonane weights (FAILS)
        //   - VNDetectFaceLandmarksRequest without usesCPUOnly → ANE SIGSEGV (CRASHES)
        //   - VNCoreMLRequest + usesCPUOnly → SIGABRT (CRASHES)
        //   - VNCoreMLRequest without usesCPUOnly → ANE SIGSEGV (CRASHES)
        //   - VNGeneratePersonInstanceMaskRequest → ANE SIGSEGV (CRASHES)
        //
        // Only safe option: VNDetectFaceRectanglesRequest (no heavy neural weights).
        // Skip YOLO entirely — use face-anchored body estimates instead.

        var bodyResults: [(CGRect, Float)] = []
        var bodyRequest: VNCoreMLRequest?
        var maskRequest: VNRequest?

        if isIOS26 {
            // === iOS 26 safe path: VNDetectFaceRectanglesRequest + direct YOLO ===

            // 1. Face detection via Vision (the one safe request)
            let faceRequest = VNDetectFaceRectanglesRequest()
            CrashGuard.shared.breadcrumb("Detector", "faceRectangles START")
            CrashGuard.shared.flushToDisk()

            do {
                try handler.perform([faceRequest])
                CrashGuard.shared.breadcrumb("Detector", "faceRectangles OK faces=\(faceRequest.results?.count ?? 0)")
            } catch {
                CrashGuard.shared.breadcrumb("Detector", "faceRectangles FAILED: \(error.localizedDescription)")
                await LogStore.shared.log(.error, "Detector", "Face detection failed: \(error.localizedDescription)")
            }
            let faceResults = parseFaceRectangleResults(faceRequest)

            // 2. YOLO body detection via direct MLModel.prediction() (bypasses Vision's broken ANE)
            var bodyResults: [(CGRect, Float)] = []
            if let yolo = yoloDirectModel, let outputName = yoloOutputName {
                CrashGuard.shared.breadcrumb("Detector", "YOLO direct predict START")
                CrashGuard.shared.flushToDisk()
                do {
                    let bodies = try directYOLODetect(ciImage: ciImage, model: yolo, outputName: outputName)
                    bodyResults = bodies
                    CrashGuard.shared.breadcrumb("Detector", "YOLO direct OK bodies=\(bodies.count)")
                } catch {
                    CrashGuard.shared.breadcrumb("Detector", "YOLO direct FAILED: \(error.localizedDescription)")
                    await LogStore.shared.log(.error, "Detector", "YOLO direct failed: \(error.localizedDescription)")
                }
            }

            CrashGuard.shared.breadcrumb("Detector", "detect() done faces=\(faceResults.count) bodies=\(bodyResults.count)")
            return mergeDetections(faces: faceResults, bodies: bodyResults, maskBoxes: [])
        }

        // Pre-iOS 26: full detection pipeline
        let faceRequest = VNDetectFaceLandmarksRequest()
        faceRequest.revision = VNDetectFaceLandmarksRequestRevision3

        var requests: [VNRequest] = [faceRequest]

        if let model = yoloVisionModel {
            let req = VNCoreMLRequest(model: model)
            req.imageCropAndScaleOption = .scaleFill
            requests.append(req)
            bodyRequest = req
        }

        if #available(iOS 17.0, *) {
            let req = VNGeneratePersonInstanceMaskRequest()
            requests.append(req)
            maskRequest = req
        }

        let requestNames = requests.map { String(describing: type(of: $0)).replacingOccurrences(of: "VN", with: "") }
        CrashGuard.shared.breadcrumb("Detector", "perform(\(requestNames.joined(separator: ","))) START")
        CrashGuard.shared.flushToDisk()
        try handler.perform(requests)
        CrashGuard.shared.breadcrumb("Detector", "detect() requests done")

        // Extract YOLO body results after perform (avoids data race from completion handler)
        if let req = bodyRequest,
           let observations = req.results as? [VNRecognizedObjectObservation] {
            for obs in observations {
                let topLabel = obs.labels.first
                if topLabel?.identifier == "person" || topLabel?.identifier == "0" {
                    let flipped = VisionCoordinates.flipToTopLeft(obs.boundingBox)
                    bodyResults.append((flipped, obs.confidence))
                }
            }
        }

        // Extract mask observation after perform
        var maskObservation: VNInstanceMaskObservation?
        if #available(iOS 17.0, *),
           let req = maskRequest as? VNGeneratePersonInstanceMaskRequest {
            maskObservation = req.results?.first
        }

        // Store for later masked crop generation
        self.lastMaskObservation = maskObservation
        self.lastHandler = handler

        // Parse instance mask bounding boxes
        var maskBoxes: [(index: Int, box: CGRect)] = []
        if let obs = maskObservation {
            maskBoxes = Self.parseMaskBoundingBoxes(obs)
        }

        let faceResults = parseFaceResults(faceRequest)
        return mergeDetections(faces: faceResults, bodies: bodyResults, maskBoxes: maskBoxes)
    }

    // MARK: - Instance Mask Parsing

    /// Extract per-instance bounding boxes from the instance mask pixel buffer.
    /// Returns normalized CGRects in top-left origin coordinate system.
    private static func parseMaskBoundingBoxes(_ observation: VNInstanceMaskObservation) -> [(index: Int, box: CGRect)] {
        let buffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // Track min/max bounds per instance label
        var bounds: [UInt8: (minX: Int, maxX: Int, minY: Int, maxY: Int)] = [:]

        for y in 0..<height {
            let rowPtr = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt8.self, capacity: width)
            for x in 0..<width {
                let label = rowPtr[x]
                if label == 0 { continue } // skip background
                if var b = bounds[label] {
                    b.minX = min(b.minX, x)
                    b.maxX = max(b.maxX, x)
                    b.minY = min(b.minY, y)
                    b.maxY = max(b.maxY, y)
                    bounds[label] = b
                } else {
                    bounds[label] = (x, x, y, y)
                }
            }
        }

        return bounds.map { (label, b) in
            // Convert to normalized top-left origin (mask buffer is already top-left)
            let rect = CGRect(
                x: CGFloat(b.minX) / CGFloat(width),
                y: CGFloat(b.minY) / CGFloat(height),
                width: CGFloat(b.maxX - b.minX + 1) / CGFloat(width),
                height: CGFloat(b.maxY - b.minY + 1) / CGFloat(height)
            )
            return (Int(label), rect)
        }.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height } // largest first
    }

    // MARK: - Face Result Parsing

    private func parseFaceResults(_ request: VNDetectFaceLandmarksRequest) -> [(CGRect, VNFaceObservation)] {
        guard let results = request.results else { return [] }
        return results.compactMap { face in
            let flipped = VisionCoordinates.flipToTopLeft(face.boundingBox)
            return (flipped, face)
        }
    }

    /// Parse face rectangles (simpler request, no landmarks — iOS 26 safe fallback).
    private func parseFaceRectangleResults(_ request: VNDetectFaceRectanglesRequest) -> [(CGRect, VNFaceObservation)] {
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

    /// Merge face, body, and instance mask detections.
    /// Priority for personBox: instanceMask > faceAnchored > yoloRaw.
    /// For each body box, counts face centroids inside to detect multi-person boxes.
    /// When multi-person, tries face-anchored estimate — uses it if cleaner (fewer faces).
    private func mergeDetections(
        faces: [(CGRect, VNFaceObservation)],
        bodies: [(CGRect, Float)],
        maskBoxes: [(index: Int, box: CGRect)] = []
    ) -> [DetectedPerson] {
        var results: [DetectedPerson] = []
        var usedFaces: Set<Int> = []
        var usedMasks: Set<Int> = []

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

            // Try to match an instance mask to this body box (>50% overlap)
            var matchedMask: (index: Int, box: CGRect)?
            for mask in maskBoxes where !usedMasks.contains(mask.index) {
                let overlap = intersectionOverMinArea(bodyRect, mask.box)
                if overlap > 0.5 {
                    matchedMask = mask
                    break
                }
            }

            // Compute personBox: instanceMask > faceAnchored > yoloRaw
            let personBox: CGRect
            let personBoxSource: PersonBoxSource
            var maskIndex: Int?

            if let mask = matchedMask {
                // Instance mask available — tightest, pixel-perfect crop
                personBox = mask.box
                personBoxSource = .instanceMask
                maskIndex = mask.index
                usedMasks.insert(mask.index)
                isMultiPerson = false // mask isolates individual
                logger.debug("Using instance mask \(mask.index) for person box")
            } else if isMultiPerson, let face = bestFace {
                let estBox = Self.estimatePersonBox(faceBox: face.rect)
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
                    source: .faceAndBody,
                    instanceMaskIndex: maskIndex
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
                    source: .bodyOnly,
                    instanceMaskIndex: maskIndex
                ))
            }
        }

        // Unmatched faces — try to match with unused masks, else estimate body
        for (fi, (faceRect, faceObs)) in faces.enumerated() where !usedFaces.contains(fi) {
            // Try matching to an unused instance mask
            var matchedMask: (index: Int, box: CGRect)?
            let faceCentroid = CGPoint(x: faceRect.midX, y: faceRect.midY)
            for mask in maskBoxes where !usedMasks.contains(mask.index) {
                if mask.box.contains(faceCentroid) {
                    matchedMask = mask
                    break
                }
            }

            let personBox: CGRect
            let personBoxSource: PersonBoxSource
            var maskIndex: Int?

            if let mask = matchedMask {
                personBox = mask.box
                personBoxSource = .instanceMask
                maskIndex = mask.index
                usedMasks.insert(mask.index)
            } else {
                personBox = Self.estimatePersonBox(faceBox: faceRect)
                personBoxSource = .faceAnchored
            }

            results.append(DetectedPerson(
                boundingBox: personBox,
                faceObservation: faceObs,
                bodyBoundingBox: nil,
                personBox: personBox,
                personBoxSource: personBoxSource,
                isMultiPerson: false,
                confidence: faceObs.confidence,
                source: .faceOnly,
                instanceMaskIndex: maskIndex
            ))
        }

        // Unmatched instance masks (no face or body matched) — add as body-only
        for mask in maskBoxes where !usedMasks.contains(mask.index) {
            results.append(DetectedPerson(
                boundingBox: mask.box,
                faceObservation: nil,
                bodyBoundingBox: nil,
                personBox: mask.box,
                personBoxSource: .instanceMask,
                isMultiPerson: false,
                confidence: 0.9, // Apple Vision confidence not exposed, use high default
                source: .bodyOnly,
                instanceMaskIndex: mask.index
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

    // MARK: - Direct YOLO Inference (iOS 26 — bypasses Vision framework)

    /// Run YOLO11n directly via MLModel.prediction(), bypassing VNCoreMLRequest.
    /// Returns person bounding boxes in normalized top-left coordinates.
    private func directYOLODetect(
        ciImage: CIImage, model: MLModel, outputName: String,
        confThreshold: Float = 0.25, iouThreshold: Float = 0.45
    ) throws -> [(CGRect, Float)] {
        // 1. Create 640×640 BGRA pixel buffer
        guard let pb = createYOLOPixelBuffer(from: ciImage) else {
            throw NSError(domain: "com.haya.ml", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create YOLO pixel buffer"])
        }

        // 2. Run prediction
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
        let output = try model.prediction(from: input)
        guard let raw = output.featureValue(for: outputName)?.multiArrayValue else {
            throw NSError(domain: "com.haya.ml", code: -1, userInfo: [NSLocalizedDescriptionKey: "YOLO output missing: \(outputName)"])
        }

        // 3. Post-process: decode boxes, filter person class, NMS
        return decodeYOLOOutput(raw, confThreshold: confThreshold, iouThreshold: iouThreshold)
    }

    /// Create a 640×640 BGRA pixel buffer from CIImage (for direct YOLO inference).
    private func createYOLOPixelBuffer(from ciImage: CIImage) -> CVPixelBuffer? {
        let size = 640
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        // Scale image to fill 640×640
        let scaleX = CGFloat(size) / ciImage.extent.width
        let scaleY = CGFloat(size) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: pb)
        return pb
    }

    /// Decode YOLO11n output tensor [1, 84, 8400] → person bounding boxes.
    /// Output layout per anchor j: [cx, cy, w, h, class0_score, ..., class79_score]
    /// Person class = 0 (COCO). Coordinates normalized to [0, 1].
    private func decodeYOLOOutput(
        _ output: MLMultiArray,
        confThreshold: Float, iouThreshold: Float
    ) -> [(CGRect, Float)] {
        let numAnchors = 8400
        let channelStride = numAnchors  // output is [1, 84, 8400], stride[1]=8400

        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(output.dataPointer))

        var boxes = [CGRect]()
        var scores = [Float]()

        for j in 0..<numAnchors {
            // Person class (index 0) score at channel 4
            let personScore = ptr[4 * channelStride + j]
            guard personScore >= confThreshold else { continue }

            // Box: cx, cy, w, h (in 640px space)
            let cx = CGFloat(ptr[0 * channelStride + j]) / 640.0
            let cy = CGFloat(ptr[1 * channelStride + j]) / 640.0
            let bw = CGFloat(ptr[2 * channelStride + j]) / 640.0
            let bh = CGFloat(ptr[3 * channelStride + j]) / 640.0

            let rect = CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh)
            boxes.append(rect)
            scores.append(personScore)
        }

        // NMS
        let kept = yoloNMS(boxes: boxes, scores: scores, threshold: iouThreshold)
        return kept.map { i in
            // Convert to top-left origin (YOLO output is already top-left)
            (boxes[i], scores[i])
        }
    }

    /// Non-maximum suppression for YOLO detections.
    private func yoloNMS(boxes: [CGRect], scores: [Float], threshold: Float) -> [Int] {
        let sorted = scores.enumerated().sorted { $0.element > $1.element }.map { $0.offset }
        var selected = [Int]()
        var active = [Bool](repeating: true, count: boxes.count)

        for i in sorted {
            guard active[i] else { continue }
            selected.append(i)
            for j in sorted where active[j] && j != i {
                let inter = boxes[i].intersection(boxes[j])
                guard !inter.isNull else { continue }
                let interArea = inter.width * inter.height
                let unionArea = boxes[i].width * boxes[i].height + boxes[j].width * boxes[j].height - interArea
                if unionArea > 0 && Float(interArea / unionArea) > threshold {
                    active[j] = false
                }
            }
        }
        return selected
    }

    // MARK: - Model URL

    private static func modelURL(name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") { return url }
        throw NSError(domain: "com.haya.ml", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model \(name) not found in bundle"])
    }
}
