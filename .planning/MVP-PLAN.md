# Haya MVP Plan — Prove the ML Pipeline Works

## Context

We've locked in 9 architectural decisions for Haya (AI-powered photo filter app). Before building the full app, we need to validate that every model in the ML pipeline actually works on-device on iPhone. The pipeline is:

```
Photo → Detect People (Apple Vision + YOLO11n)
      → Identify Person (InsightFace + OSNet)
      → Assess Modesty (Hair Seg → SmolVLM2)
      → Hide/Show
```

This MVP proves feasibility — a minimal app that runs the full pipeline on a single photo and shows results. Not the final app, just proof it works.

## Critical Research Findings

- **SmolVLM2**: Must use MLX Swift (NOT CoreML — `unfold` op unsupported in coremltools). Requires iOS 18, physical device only, "Increased Memory Limit" entitlement. Reference: HuggingSnap app.
- **InsightFace ArcFace**: Convert `w600k_r50.onnx` → CoreML via coremltools. Input: 112x112 aligned face, RGB, [-1,1]. Output: 512-dim. Face alignment with 5 landmarks is REQUIRED.
- **OSNet x0_25**: PyTorch → ONNX → CoreML. Input: 256x128 (not square!), RGB, [-1,1]. Output: 512-dim. Must set model to evaluation mode before export.
- **YOLO11n**: `ultralytics` export → `.mlpackage`. Can use ultralytics Swift package or VNCoreMLRequest.
- **Hair Seg**: MediaPipe `hair_segmenter.tflite` via CocoaPods (MediaPipeTasksVision). No SPM support. Alternative: convert to CoreML or use john-rocky/CoreML-Face-Parsing.
- **Apple Vision**: VNDetectFaceLandmarksRequest (iOS 11+), VNGeneratePersonInstanceMaskRequest (iOS 17+). Coordinates origin at bottom-left — Y-flip needed.
- **iOS target**: 18.0 (required by MLX Swift for VLM)
- **CocoaPods needed**: MediaPipe hair seg has no SPM package. Mix CocoaPods + SPM.

## Phases

### Phase 1: Model Conversion Scripts (Python)

Convert all models to iOS-ready formats before touching Xcode.

**Files to create:**
- `scripts/convert_arcface.py` — ONNX → CoreML
- `scripts/convert_osnet.py` — PyTorch → ONNX → CoreML
- `scripts/export_yolo.py` — Ultralytics → CoreML
- `scripts/requirements.txt` — Python deps

**ArcFace conversion (coremltools):**
- Source: `w600k_r50.onnx` from HuggingFace `public-data/insightface`
- Input spec: ImageType, shape (1,3,112,112), RGB, bias [-1,-1,-1], scale 1/127.5
- Target: iOS16, FP16 precision
- Output: `ArcFace.mlpackage` (~85MB)

**OSNet conversion:**
- Load pretrained `osnet_x0_25` from torchreid
- Set to evaluation mode (CRITICAL for batch norm)
- Export to ONNX with input shape (1,3,256,128) — height 256, width 128
- Convert ONNX → CoreML with same normalization as ArcFace
- Output: `OSNet.mlpackage` (~3MB)

**YOLO11n export:**
- Load `yolo11n.pt` from ultralytics
- Export with format="coreml", nms=True, half=True, imgsz=640
- Output: `YOLO11n.mlpackage` (~5MB)

**Environment:** Python 3.10/3.11 via `uv`. Packages: coremltools>=8.0, ultralytics, torchreid, torch, numpy<2.

### Phase 2: Xcode Project Setup

**Create project:**
- Xcode → New Project → iOS App → SwiftUI → Swift
- Product name: Haya
- Deployment target: iOS 18.0

**Swift Package Manager dependencies:**
```
https://github.com/ml-explore/mlx-swift-lm  (MLXLLM, MLXVLM, MLXLMCommon)
```

**CocoaPods (Podfile):**
```ruby
platform :ios, '18.0'
target 'Haya' do
  use_frameworks!
  pod 'MediaPipeTasksVision', '~> 0.10'
end
```

**Add CoreML models to project:**
- Drag `ArcFace.mlpackage`, `OSNet.mlpackage`, `YOLO11n.mlpackage` into Xcode navigator
- Xcode auto-generates Swift classes

**Bundle hair_segmenter.tflite:**
- Download from MediaPipe models storage
- Add to project bundle

**Info.plist keys:**
- `NSPhotoLibraryUsageDescription` — photo library access

**Entitlements:**
- Increased Memory Limit (for VLM)
- Outgoing Connections / Client (for HuggingFace model download)

**Project structure:**
```
Haya/
├── HayaApp.swift
├── ContentView.swift
├── ML/
│   ├── PersonDetector.swift        — Apple Vision + YOLO11n
│   ├── PersonIdentifier.swift      — InsightFace + OSNet + cosine similarity
│   ├── HairSegmenter.swift         — MediaPipe hair seg
│   ├── VLMService.swift            — SmolVLM2 via MLX Swift
│   └── Pipeline.swift              — Orchestrates full pipeline
├── Views/
│   ├── PhotoGridView.swift         — Photo library grid
│   ├── PhotoDetailView.swift       — Single photo with overlays
│   ├── EnrollmentView.swift        — Select photos to enroll a person
│   └── ResultsView.swift           — Pipeline results display
├── Models/
│   ├── ArcFace.mlpackage
│   ├── OSNet.mlpackage
│   └── YOLO11n.mlpackage
├── Resources/
│   └── hair_segmenter.tflite
└── Utilities/
    ├── EmbeddingMath.swift         — Cosine similarity via Accelerate/vDSP
    ├── FaceAligner.swift           — 5-point affine alignment for ArcFace
    └── VisionCoordinates.swift     — Vision bottom-left ↔ SwiftUI top-left conversion
```

### Phase 3: Person Detection (Apple Vision + YOLO11n)

**Goal:** Given a photo, detect all people (faces + bodies) and draw bounding boxes.

**PersonDetector.swift:**
1. `VNDetectFaceLandmarksRequest` → face bounding boxes + 76 landmarks + confidence
2. `YOLO11n` CoreML via `VNCoreMLRequest` → body bounding boxes (class "person") + confidence
3. Merge results (avoid double-counting when face + body boxes overlap significantly)
4. Return array of `DetectedPerson` structs: boundingBox, faceLandmarks (optional), source (face/body/both), confidence

**VisionCoordinates.swift:**
- Convert Vision normalized coords (origin bottom-left) to SwiftUI (origin top-left)
- Formula: `swiftUIY = 1.0 - visionY - visionHeight`

**PhotoDetailView.swift:**
- Display photo with colored bounding box overlays using GeometryReader + ZStack
- Green = face detected, Blue = body detected, Purple = both
- Show confidence scores as text labels

**Verify:** Pick 5+ test photos covering: front face, side profile, back view, sitting at desk, group photo → all people detected with correct boxes.

### Phase 4: Person Identification (InsightFace + OSNet)

**Goal:** Enroll a person from 5 photos, then identify them in new photos.

**FaceAligner.swift:**
- Extract 5 landmarks from VNFaceObservation: left eye center, right eye center, nose tip, left mouth corner, right mouth corner
- Canonical 112x112 target positions: [(38.29, 51.70), (73.53, 51.50), (56.03, 71.74), (41.55, 92.37), (70.73, 92.20)]
- Compute similarity transform (not full affine — preserve aspect ratio)
- Apply via CIImage affineTransform → crop to 112x112 → CVPixelBuffer

**PersonIdentifier.swift:**
1. Face path: aligned 112x112 crop → ArcFace CoreML → 512-dim Float array
2. Body path: body crop resized to 256x128 → OSNet CoreML → 512-dim Float array
3. Enrollment: user selects 5+ photos → extract embeddings → average into centroid → store
4. Matching: new photo's embedding vs stored centroids via cosine similarity
5. Thresholds: ~0.5 for face match, ~0.3 for body match (tune during testing)

**EmbeddingMath.swift:**
- Cosine similarity using Accelerate framework (vDSP_dotpr + vDSP_svesq)
- L2 normalization helper
- Batch comparison: query embedding vs array of centroids → sorted matches

**EnrollmentView.swift:**
- PhotosPicker to select 5+ photos of a person
- Show progress: extracting embeddings...
- Display result: "Enrolled: Sarah — 5 face embeddings averaged, 3 body embeddings averaged"
- Store centroid in local JSON file (MVP — not database)

**Verify:** Enroll a person → present new photos → correctly identifies them with similarity scores. Test cases: face visible (high face similarity), side angle (lower face, higher body), back only (body embedding match only).

### Phase 5: Modesty Detection (Hair Seg + SmolVLM2)

**Goal:** For an identified person, determine if they're modestly dressed.

**HairSegmenter.swift:**
- Load hair_segmenter.tflite via MediaPipeTasksVision ImageSegmenter
- Input: head region crop from detected person
- Output: category mask (pixel=1 → hair, pixel=0 → background)
- Compute: `hairRatio = count(hair pixels) / count(total head pixels)`
- Decision: hairRatio > 0.4 → HIDE immediately (lots of hair, skip VLM)
- Otherwise → pass to VLM for full modesty check

**VLMService.swift:**
```swift
import MLXLMCommon

// Load model (downloads ~500MB on first launch)
let model = try await loadModel(id: "mlx-community/SmolVLM2-256M-Video-Instruct-mlx")
let session = ChatSession(model, processing: .init(resize: CGSize(width: 384, height: 384)))

// Assess modesty
let answer = try await session.respond(
    to: """
    Is this person wearing hijab and dressed modestly?
    Check: hair fully covered, arms covered, legs covered, loose clothing.
    Answer: YES or NO, then confidence (high/medium/low), then brief reason.
    """,
    image: .ciImage(personCropImage)
)
```

**Start with SmolVLM2-256M for faster iteration during MVP.** Upgrade to 2.2B after proving it works.

**ResultsView.swift:**
- Show full pipeline results for a photo:
  - Detected: 2 people (face + body)
  - Person 1: Identified as "Sarah" (face: 0.87, body: 0.72)
  - Hair ratio: 0.05 (low → checking VLM)
  - VLM says: "YES, modestly dressed. Confidence: high. Reason: wearing hijab, long sleeves, long skirt."
  - Decision: KEEP

**Verify with test cases:**
- Hijab + modest dress → KEEP
- No hijab, hair visible → HIDE (caught by Hair Seg, ratio > 0.4)
- Beanie + shorts + tank top → HIDE (Hair Seg passes, VLM catches exposed arms/legs)
- Back of head + modest dress → KEEP (VLM understands context)
- Towel on head + exposed body → HIDE (VLM catches it)

### Phase 6: End-to-End Pipeline + Toggle

**Goal:** Wire everything into a usable mini-app.

**Pipeline.swift — orchestrator:**
```
processPhoto(asset) → FilterResult:
  1. Load image
  2. Detect people (PersonDetector)
  3. For each person, try identify (PersonIdentifier)
  4. If matched to enrolled person:
     a. Check filter mode (alwaysHide → done)
     b. Run hair seg (ratio > threshold → HIDE)
     c. Run VLM with person's prompt → HIDE or KEEP
  5. Return result
```

**Memory management:**
- Don't load all models simultaneously
- Load detection models (small) persistently
- Load VLM on-demand, release after batch
- Use `MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)`

**PhotoGridView.swift:**
- Display photos from library in LazyVGrid
- Hidden photos show blur overlay when toggle is ON
- Toggle in toolbar, protected by LocalAuthentication (FaceID/TouchID)

**Auth toggle:**
```swift
import LocalAuthentication
let context = LAContext()
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reveal hidden photos")
```

**Verify full pipeline on 20+ photos:**
- Correct detection → identification → assessment → hide/show
- Performance: measure time per photo at each stage
- Memory: no crashes, stays under memory limit
- Auth: FaceID toggle works correctly

## Key Dependencies Summary

| Dependency | Source | Purpose |
|---|---|---|
| mlx-swift-lm | SPM | SmolVLM2 inference |
| MediaPipeTasksVision | CocoaPods | Hair segmentation |
| ArcFace w600k_r50 | ONNX → CoreML | Face embeddings (512-dim) |
| OSNet x0_25 | PyTorch → CoreML | Body embeddings (512-dim) |
| YOLO11n | Ultralytics → CoreML | Body detection |
| SmolVLM2-256M | HF Hub (runtime download) | Modesty VLM |

## Environment Requirements

- macOS with Xcode 16+
- Physical iPhone (iOS 18+, A14+ chip) — no simulator for MLX or Vision masks
- Python 3.10/3.11 with uv for model conversion
- CocoaPods installed
- ~2GB free space on iPhone for models

## Verification Checklist

- [ ] Phase 1: All 3 `.mlpackage` files generated without errors
- [ ] Phase 2: App builds, photo library permission works, photos display
- [ ] Phase 3: Bounding boxes on faces AND bodies (front, side, back, group)
- [ ] Phase 4: Enroll person → identify in new photos → correct similarity scores
- [ ] Phase 5: Hair seg returns ratios. VLM answers correctly for 5+ test cases
- [ ] Phase 6: Full pipeline on 20+ photos. Toggle hides/reveals with FaceID

## Risk Mitigation

| Risk | Mitigation |
|---|---|
| SmolVLM2 too slow | Start with 256M. Profile. Pre-process only new photos. |
| ArcFace CoreML conversion fails | Fallback: ONNX Runtime Swift package |
| MediaPipe CocoaPods conflicts with SPM | Fallback: convert hair_segmenter to CoreML, drop pod |
| Face alignment inaccurate | Test with Vision landmarks first. Fallback: dlib via C++ |
| VLM hallucination | Tune prompt. Add structured output constraint. Test extensively. |
| Memory pressure | Load/unload models per pipeline stage. Don't keep VLM + ArcFace simultaneously. |
