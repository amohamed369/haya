# Haya MVP — Complete Research Findings

## SmolVLM2 on iOS (VERIFIED)

### Framework: MLX Swift (NOT CoreML)
- CoreML conversion is BROKEN — `unfold` op unsupported (coremltools issue #2599, still open)
- Must use MLX Swift via SPM: `https://github.com/ml-explore/mlx-swift-lm`
- Reference app: HuggingSnap (https://github.com/huggingface/HuggingSnap)

### Model Loading & Inference (Context7 verified)
```swift
import MLXLMCommon
let model = try await loadModel(id: "mlx-community/SmolVLM2-256M-Video-Instruct-mlx")
let session = ChatSession(model, processing: .init(resize: CGSize(width: 384, height: 384)))
let answer = try await session.respond(to: "Is this person modestly dressed?", image: .url(imageURL))
```

### Available Models (HuggingFace Hub, MLX format)
| Model | Hub ID | Size |
|---|---|---|
| SmolVLM2-2.2B 4-bit | smdesai/SmolVLM2-2.2B-Instruct-4bit | ~1.46GB |
| SmolVLM2-500M | mlx-community/SmolVLM2-500M-Video-Instruct-mlx | ~1.02GB |
| SmolVLM2-256M | mlx-community/SmolVLM2-256M-Video-Instruct-mlx | <1GB |

### Critical Requirements
- iOS 18, physical device only, "Increased Memory Limit" entitlement
- "Outgoing Connections (Client)" for HF download
- Release build 10x faster than debug
- `MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)`

---

## InsightFace ArcFace on iOS (VERIFIED)

### Source: w600k_r50.onnx from HuggingFace public-data/insightface (~174MB)

### ONNX to CoreML Conversion
```python
import coremltools as ct
model = ct.convert("w600k_r50.onnx", source="onnx",
    inputs=[ct.ImageType(name="input.1", shape=(1,3,112,112),
            bias=[-1,-1,-1], scale=1.0/127.5, color_layout=ct.colorlayout.RGB)],
    minimum_deployment_target=ct.target.iOS16, compute_precision=ct.precision.FLOAT16)
model.save("ArcFace.mlpackage")
```
Requires Python 3.10/3.11, coremltools>=8.0, numpy<2

### Face Alignment (MANDATORY)
- 5-point landmarks: left eye, right eye, nose, left mouth, right mouth
- Canonical 112x112 targets: [(38.29,51.70), (73.53,51.50), (56.03,71.74), (41.55,92.37), (70.73,92.20)]
- Without alignment embeddings are garbage

### Input/Output
- Input: 112x112 aligned face, RGB, [-1,1]
- Output: 512-dim Float array

---

## OSNet x0_25 on iOS (VERIFIED)

### Conversion: PyTorch → ONNX → CoreML
- Load from torchreid, SET TO EVALUATION MODE (critical for batch norm)
- Export ONNX with shape (1,3,256,128) — height 256, width 128 (NOT square)
- Then ONNX → CoreML same as ArcFace
- Output: ~3MB CoreML model, 512-dim embedding

---

## YOLO11n on iOS (VERIFIED)

### Export
```python
from ultralytics import YOLO
model = YOLO("yolo11n.pt")
model.export(format="coreml", nms=True, half=True, imgsz=640)
```
Output: ~5MB .mlpackage

### Swift: Use VNCoreMLRequest or ultralytics/yolo-ios-app SPM package

---

## Apple Vision (Context7 VERIFIED)

### Face Detection (iOS 11+)
```swift
let request = VNDetectFaceLandmarksRequest()
let handler = VNImageRequestHandler(cgImage: image)
try handler.perform([request])
let faces: [VNFaceObservation] = request.results ?? []
```

### Person Instance Masks (iOS 17+)
- VNGeneratePersonInstanceMaskRequest — up to 4 individual person masks
- VNGeneratePersonSegmentationRequest — fallback for >4 people
- Apple pattern: count faces first, choose request type accordingly

### Coordinates: normalized [0,1], origin BOTTOM-LEFT. Y-flip needed for SwiftUI.

---

## MediaPipe Hair Segmentation (VERIFIED)

### CocoaPods only (no SPM): `pod 'MediaPipeTasksVision', '~> 0.10'`

### Model: hair_segmenter.tflite (~1MB, 512x512 input/output)
Download: `https://storage.googleapis.com/mediapipe-models/image_segmenter/hair_segmenter/float32/latest/hair_segmenter.tflite`

### Apple built-in NOT usable:
- AVSemanticSegmentationMatte(.hair) = camera-captured only, NOT library photos
- VNGeneratePersonSegmentationRequest = whole person, NOT hair-specific

### Fallback: john-rocky/CoreML-Face-Parsing (already CoreML, has hair category)

---

## Cosine Similarity (Accelerate/vDSP)
```swift
import Accelerate
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, magA: Float = 0, magB: Float = 0
    let n = vDSP_Length(a.count)
    vDSP_dotpr(a, 1, b, 1, &dot, n)
    vDSP_svesq(a, 1, &magA, n)
    vDSP_svesq(b, 1, &magB, n)
    return dot / (sqrt(magA) * sqrt(magB))
}
```

---

## PhotoKit: Use PHAsset.fetchAssets, PHImageManager, PHPersistentChangeToken (iOS 16+)
## SwiftUI: PhotosPicker for enrollment, LazyVGrid for grid, @Observable (iOS 17+)
## iOS Target: 18.0 (MLX requirement). Python: 3.10/3.11 (coremltools requirement).

## Key Repos
- HuggingSnap: github.com/huggingface/HuggingSnap
- mlx-swift-lm: github.com/ml-explore/mlx-swift-lm
- ultralytics/yolo-ios-app: github.com/ultralytics/yolo-ios-app
- CoreML-Face-Parsing: github.com/john-rocky/CoreML-Face-Parsing
- ONNX Runtime Swift: github.com/microsoft/onnxruntime-swift-package-manager
