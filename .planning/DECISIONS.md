# Haya — All Decisions, Options & Choices

## App Overview

**Haya** — A photo gallery app that auto-hides photos based on configurable per-person criteria. Default use case: hiding non-hijabi/non-modest photos of configured people. Works for ALL poses/angles — face not visible, side, back, etc.

### Core Requirements
- 100% on-device processing (privacy critical — photos never leave phone)
- Free to start ($0 budget except Apple Developer $99/year)
- Fast and responsive
- Works for all poses and angles (face, side, back, partial body)
- User feedback loop to improve detection over time
- Per-person and per-group customizable filter criteria
- Auth-protected toggle to reveal hidden photos

### Key Insight
The app is NOT just a hijab detector — it's an **AI-powered photo filter with customizable criteria**. Hijab/modesty is the default, but users can set any filter per person ("always hide", "smoking", "drinking", custom prompts).

---

## Decision 1: Platform — NATIVE SWIFT (iOS-first)

### Why Native Swift Won
- Direct access to Apple Vision framework, CoreML, Neural Engine
- PhotoKit integration for reading photo library
- MLUpdateTask for on-device learning
- Best performance for ML inference
- No bridge overhead (React Native/Flutter would add latency)

### Options Considered
| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Native Swift** | Full Apple API access, best perf, CoreML native | iOS only | **CHOSEN** |
| React Native | Cross-platform | Bridge overhead, limited Vision API access, worse ML perf | Rejected |
| Flutter | Cross-platform, good UI | Same issues as RN for ML | Rejected |
| Kotlin (Android) | Native Android | Different platform, not user's priority | Future maybe |

---

## Decision 2: Architecture — PHOTO VIEWER WITH AUTH TOGGLE

### How It Works
- App IS a photo viewer (reads from Apple Photos via PhotoKit)
- Photos **never move** — they stay in Apple Photos library
- Toggle ON = non-matching photos hidden from app view
- Toggle OFF = see everything (requires FaceID/passcode)
- Users can manually select photos to hide too
- Per-person and per-group filter configuration
- Custom prompts per person/group

### Filter Modes Per Person/Group
1. **Default prompt** — "Is this person wearing hijab and dressed modestly?" (user-editable default)
2. **Custom prompt** — any criteria the user types ("smoking", "drinking", "not wearing seatbelt", etc.)
3. **Always hide** — skip AI entirely, hide ALL photos of this person

### Grouping System
```
Groups:
┌──────────────┬────────────────────────┬─────────────────┐
│ "Family Women"│ Sarah, Mom, Aunt      │ "not modest"    │
│ "Hide Always" │ Brother, Ex           │ ALWAYS HIDE     │
│ "Custom"      │ Dad                   │ "smoking"       │
└──────────────┴────────────────────────┴─────────────────┘
```

### Options Considered
| Option | Description | Verdict |
|--------|-------------|---------|
| Safe Viewer (hide in place) | Filter from view only | Evolved into chosen approach |
| Auto-Vault (move + encrypt) | Move photos to encrypted container | Over-engineered, photos shouldn't move |
| Hybrid (hide + optional vault) | Default filter, optional vault | Unnecessary complexity |
| Apple Hidden Album | Use iOS Hidden album | Still accessible in Photos app |
| **Photo Viewer + Auth Toggle** | View with auth-protected toggle, per-person config | **CHOSEN** |

---

## Decision 3: Person Detection — APPLE VISION (faces) + YOLO11n (bodies)

### What This Solves
"Where are people in this photo?" — detects and locates all people regardless of pose/angle.

### Architecture
```
Photo Input
    ├─ Apple Vision VNDetectFaceLandmarksRequest → face bounding boxes + 76 landmarks
    └─ YOLO11n CoreML → full body bounding boxes (any angle: front, side, back, sitting)

iOS 17+: Also use VNGeneratePersonInstanceMaskRequest for precise body segmentation
iOS 15-16: VNGeneratePersonSegmentationRequest (less precise)
iOS <15: YOLO11n only
```

### Apple Vision Details
- **VNDetectFaceLandmarksRequest**: Detects faces, returns bounding boxes, 76 facial landmarks, yaw/pitch/roll, confidence score
- **VNGeneratePersonInstanceMaskRequest** (iOS 17+): Segments individual people in image, returns pixel masks, derives bounding boxes, handles up to 4 people
- **VNGeneratePersonSegmentationRequest** (iOS 15+): Single mask for all people (less granular)
- Hardware-accelerated, <1ms, free, built into iOS

### YOLO11n Details
- CNN-based object detector, ~5MB CoreML model
- Detects full body bounding boxes from ANY angle (front, side, back, sitting, partial)
- ~20ms inference on iPhone
- Trained on COCO dataset (80 classes, "person" is class 0)
- No training needed — use pretrained model directly
- Export: `from ultralytics import YOLO; model = YOLO('yolo11n-seg.pt'); model.export(format='coreml')`

### Why Both
- Apple Vision is best for faces (free, hardware-accelerated, landmark data)
- Apple Vision can miss people from behind or with face obscured
- YOLO catches ALL people regardless of whether face is visible
- Together = comprehensive detection from any angle

### Options Considered
| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| Apple Vision only | Free, built-in, fast | Misses people without visible faces | Partial — used for faces |
| YOLO11n only | Catches all angles | Doesn't give facial landmarks | Partial — used for bodies |
| YOLOv5Face | Face-specific YOLO | Older, face-only like Apple Vision | Rejected |
| **Apple Vision + YOLO11n** | Complete coverage all angles | Two models | **CHOSEN** |

### Code Pattern (Swift)
```swift
// Apple Vision face detection
import Vision
let faceRequest = VNDetectFaceLandmarksRequest()
let handler = VNImageRequestHandler(cgImage: cgImage)
try handler.perform([faceRequest])
let faces = faceRequest.results ?? []
// Each face: boundingBox, confidence, yaw, pitch, roll, 76 landmarks

// YOLO11n body detection
let model = try VNCoreMLModel(for: YOLO11n().model)
let bodyRequest = VNCoreMLRequest(model: model) { req, _ in
    let results = req.results as? [VNRecognizedObjectObservation]
    let people = results?.filter { $0.labels.first?.identifier == "person" }
}
try handler.perform([bodyRequest])

// iOS version fallback
if #available(iOS 17.0, *) {
    // VNGeneratePersonInstanceMaskRequest (best, individual segmentation)
} else if #available(iOS 15.0, *) {
    // VNGeneratePersonSegmentationRequest (good, single mask)
} else {
    // YOLO11n only
}
```

---

## Decision 4: Person Identification — INSIGHTFACE + CLIP-ReID + TEMPORAL CLUSTERING

### What This Solves
"WHO is this person?" — matches detected people against configured people using face and body embeddings.

### Architecture
```
Detected Person
    ├─ Face visible? → InsightFace ArcFace → 512-dim face embedding
    ├─ Body visible? → CLIP-ReID ViT-B/16 → 512-dim body embedding
    └─ Compare against stored centroids via cosine similarity

Matching (face-primary, 2 pathways only):
    ├─ Face similarity >= 0.35 → MATCH (authoritative biometric)
    └─ Body similarity >= 0.80 → MATCH (CLIP-ReID makes this reliable)

Additional signal: Temporal Clustering
    → Photos taken same time/place likely contain same people
```

### Why CLIP-ReID Replaced OSNet (Round 8)
44-photo Kaggle test revealed 3 identity false positives caused by the old weak_face+body pathway (OSNet matched clothing, not identity). Research showed:
- **OSNet x0_25**: 3MB CNN, matches clothing texture — two people in similar outfits get matched as same person
- **CLIP-ReID ViT-B/16**: 165MB FP16 (45-50MB INT4 on iPhone), understands visual identity semantically via CLIP image projection space
- Apple Photos uses face as primary, body only within same "moment" — body re-ID fundamentally matches clothing for ALL lightweight models
- CLIP-ReID is the best available iPhone-compatible body matcher

### CLIP-ReID Technical Details
- **Model**: ViT-B/16 fine-tuned for person re-identification
- **Checkpoint**: MSMT17 SIE-OLP variant (1041 training identities, best cross-domain)
- **Input**: 256x128 RGB, normalized mean=[0.5,0.5,0.5] std=[0.5,0.5,0.5]
- **Output**: 512-dim CLIP image projection via `model(x, get_image=True)`
- **Inference**: `make_model()` returns concatenated [768+512] features; `get_image=True` returns just the 512-dim projection
- **Notebook**: FP32 model, FP16 I/O wrapper (LayerNorm requires FP32 internally)
- **iPhone**: CoreML FP16 → INT4 quantization (per_block, block_size=32) → ~45-50MB
- **Conversion**: `scripts/convert_clipreid.py` — trace, convert, quantize, verify
- **Google Drive ID**: `1sPZbWTv2_stXBGutjHMvE87pAbSAgVaz` (official README)
- **Loading**: Robust filter — skip shape-mismatched keys (classifiers + pos embed from OLP variant), load all backbone weights

### Weak Pathway Removed (Round 8)
Previously had 3 matching pathways:
1. Face >= 0.35 (kept)
2. ~~Weak face >= 0.25 AND body >= 0.7~~ **(REMOVED — caused false positives)**
3. Body >= 0.80 (kept)

The weak_face+body pathway was the source of identity false positives — strangers with similar clothing were matched when InsightFace gave a weak (but above 0.25) face score. With CLIP-ReID, body-only matching at 0.85 is reliable enough.

### Model Details
| Model | Purpose | Size (iPhone) | Embedding | Notes |
|-------|---------|---------------|-----------|-------|
| InsightFace ArcFace | Face recognition | ~85MB FP16 | 512-dim | 99.8% LFW, biometric-grade |
| CLIP-ReID ViT-B/16 | Body re-identification | ~45-50MB INT4 | 512-dim | CLIP visual projection space |

### Options Considered
| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| InsightFace only | Best face recognition | Useless without visible face | Partial |
| OSNet x0_25 | 3MB, fast | Matches clothing not identity, caused false positives | **REPLACED by CLIP-ReID** |
| CLIP-ReID ViT-B/16 | Semantic body understanding, CLIP space | 45-50MB INT4 | **CHOSEN** |
| KPR (Keypoint Prompted Re-ID) | SOTA re-ID, Swin Transformer | Not mobile-ready, huge model | Rejected |
| VNFeaturePrint (Apple) | Zero model size, 768-dim | Untested for person re-ID | Potential future fallback |
| **InsightFace + CLIP-ReID + Temporal** | Full coverage, all angles, semantic body matching | Two models | **CHOSEN** |

### Why NOT Fine-Tuning on User Images
- Only 5-10 enrollment photos per person = too few for fine-tuning
- Fine-tuning overfits on small datasets (memorizes rather than learns)
- Embedding averaging is simpler, proven, and works with few images
- Industry standard approach (Apple Photos, Google Photos use this)

### Why NOT KPR
- Swin Transformer backbone = too large for mobile
- No proven mobile deployment
- Research paper only, no production-ready implementation

---

## Decision 5: Modesty Detection — HAIR SEG (pre-filter) → VLM (full check)

### What This Solves
"Is this person dressed modestly?" — not just hair, but full modesty assessment.

### Key Insight: It's Not Just About Hair
Early discussion focused on hijab/hair detection. But edge cases revealed the need for full modesty assessment:
- **Beanie + shorts**: Hair covered but not modest → should HIDE
- **Towel on head + naked (shower)**: Hair covered, body exposed → should HIDE
- **Hoodie + tank top**: Partially covered → depends on user standards
- **Any head covering counts as hijab**: Beanie, hoodie, towel, turban, scarf — all valid if user considers them valid

Therefore the check must assess **overall modesty**, not just hair coverage.

### Architecture
```
Layer 0: NSFW Pre-filter (instant HIDE for explicit content)
         ├─ iOS: Apple SensitiveContentAnalysis (if user enabled — bonus, not required)
         ├─ Colab POC: Marqo/nsfw-image-detection-384 (22MB ViT, 98.56% accuracy)
         └─ NSFW detected → HIDE immediately (skip all other checks)

Layer 1: MediaPipe Hair Segmentation (fast pre-filter, <5ms)
         ├─ Lots of hair visible (>0.4 ratio) → HIDE immediately (skip VLM)
         └─ Anything else → Layer 2 (need full assessment)

Layer 2: VLM Decomposed 5-Question Check (200-500ms per question)
         → 5 separate YES/NO questions (bias-aligned polarity):
         Q1: "Is hair covered?" YES=PASS (normal polarity)
         Q2: "Can you see bare arms?" YES=FAIL (flipped — NO-bias = PASS when covered)
         Q3: "Can you see bare legs?" YES=FAIL (flipped)
         Q4: "Is clothing tight/form-fitting?" YES=FAIL (flipped)
         Q5: "Can you see bare chest/cleavage/midriff/back?" YES=FAIL (flipped)
         ├─ All pass → KEEP
         ├─ Any fail → HIDE
         └─ Ambiguous → HIDE (privacy-first)
```

### Why Decomposed Questions (Not Single Prompt)
- Single complex prompt → VLM misses details or gives inconsistent answers
- Decomposed → each question is simple YES/NO, much more reliable
- Q2-Q5 use FLIPPED polarity to work WITH VLM's NO-bias (Qwen2.5-VL-3B defaults to NO)
- When person IS covered → NO-bias says "NO bare skin" = PASS ✓
- When person is NOT covered → visual evidence overrides bias → YES = FAIL ✓
- Validated in Colab Round 4 testing

### NSFW Pre-Filter Details
**Colab (Marqo/nsfw-image-detection-384)**:
- 22MB ViT-tiny model, `pip install timm`
- Binary NSFW/SFW output with probability score
- Threshold tunable (default 0.5)
- Catches explicit nudity BEFORE running expensive VLM questions

**iOS (Apple SensitiveContentAnalysis)**:
- iOS 17+ only, `SCSensitivityAnalyzer` API
- Requires user to enable "Sensitive Content Warning" in iOS Settings
- Binary result (sensitive/not), no scores
- NOT a core dependency — bonus pre-filter when available
- Entitlement: `com.apple.developer.sensitivecontentanalysis.client` (non-restricted, any paid dev account)
- Does NOT work in Simulator — physical device only
- Only detects nudity, NOT modesty — complementary to VLM, not a replacement

### Why Hair Seg is Just a Pre-Filter
- Hair Seg only answers "is hair visible?" — pixel-level hair detection
- It can't assess clothing, body coverage, or context
- It has NO concept of what's covering the head (beanie vs hijab vs towel)
- But it's very fast — if lots of hair is clearly visible, you already know the answer without running the expensive VLM
- ~70-80% of obvious cases resolved at this layer

### Why VLM is the Primary Brain
- Only model that understands "shorts + tank top + towel on head ≠ modest"
- Understands cultural context and garment types
- Can follow custom prompts ("is this person smoking?")
- Handles all edge cases through natural language understanding

### Confidence-Based Cascade
Every layer produces confidence scores:
- **Hair Seg**: hair pixel ratio (0.0-1.0) — clear-cut = high confidence, ambiguous = low
- **VLM**: prompted to output confidence in structured response

Low confidence at any layer → escalate or flag for review.

### MediaPipe Hair Segmentation Details
- 1MB TFLite model, 100+ FPS
- Outputs per-pixel mask (0.0-1.0 probability of being hair)
- Derive: `hairRatio = hairPixels / headRegionPixels`
- Inverse logic: no hair visible = head covered (but doesn't tell you BY WHAT)

### Options Considered
| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| MediaPipe Hair Seg only | 1MB, 100+ FPS, simple | Only detects hair, can't assess full modesty | Pre-filter only |
| YOLOv11n fine-tuned hijab | Detects hijab garment specifically | Can't assess full modesty, misses edge cases | Rejected (any covering counts) |
| MobileCLIP zero-shot | Text-image similarity | Less accurate than VLM for nuanced questions | Rejected |
| VLM only | Handles everything | Slow on every photo | Too slow as only layer |
| **Hair Seg + VLM** | Fast pre-filter + smart full check | Two models | **CHOSEN** |

### Why YOLO Hijab Detector Was Dropped
Originally proposed a 3-layer cascade with a YOLO model trained specifically on hijab images. Dropped because:
- User clarified ANY head covering counts (beanie, hoodie, towel, etc.)
- Not looking for a specific garment — looking for absence of hair / overall modesty
- Training a "hijab detector" is the wrong framing
- VLM handles the full modesty question better

---

## Decision 6: VLM Choice — QWEN2.5-VL-3B (Colab POC) / SMOLVLM2-2.2B (iOS target)

### What This Solves
Which on-device Vision Language Model to run for the modesty assessment.

### Architecture
```
Device RAM check at app launch:
    ├─ ≥6GB RAM (iPhone 13+) → Load SmolVLM2-2.2B (4-bit quantized)
    └─ <6GB RAM (iPhone 12)  → Load SmolVLM2-256M
```

### SmolVLM2-2.2B (Default)
- ~1.5-2GB RAM, ~1.2GB disk (4-bit quantized)
- Best accuracy for nuanced modesty questions
- Handles edge cases well (towel + shorts, cultural variations)
- Needs iPhone 13 Pro+ (6GB RAM) realistically
- Proven ecosystem: HuggingFace HuggingSnap app, MLX Swift framework

### SmolVLM2-256M (Fallback)
- ~0.8GB RAM, ~500MB disk
- Good enough for straightforward modesty questions
- Runs on iPhone 12 (4GB RAM)
- Same ecosystem as 2.2B — same code, different model file

### Why SmolVLM2
- **Proven on iOS** — HuggingSnap is a real shipping app
- **HuggingFace ecosystem** — MLX Swift, CoreML conversion tools, community
- **Size variants** — same architecture at different sizes, easy to swap

### Options Considered
| Option | Size (RAM) | Speed | Proven on iOS | Verdict |
|--------|-----------|-------|--------------|---------|
| SmolVLM2-256M | 0.8GB | Fast | Yes (HuggingSnap) | Fallback for older devices |
| SmolVLM2-500M | 1.5GB | Medium | Yes | Middle ground, skipped |
| **SmolVLM2-2.2B** | 1.5-2GB | Slower | Yes (ecosystem) | **DEFAULT** |
| FastVLM-0.5B (Apple) | 1.5-2GB | Fast (Apple optimized) | Research paper only | Too risky for v1 |
| Moondream2 | ~2GB | Medium | No proven iOS deployment | Rejected |
| Qwen2-VL | Large | Slow | No proven iOS deployment | Rejected |
| PaliGemma | Large | Slow | No proven iOS deployment | Rejected |

### Why NOT Cloud API (GPT-4V, Claude Vision, Gemini)
- **Privacy**: Sending modesty photos to third-party servers contradicts app's purpose
- **Cost**: $0.01-0.03 per image × thousands of photos = $50-150+
- **Speed**: 1-5 seconds network latency vs 200-500ms on-device
- **Offline**: Won't work without internet
- Could be optional future toggle for users who don't care about privacy

---

## Decision 7: User Feedback Loop — THRESHOLD TUNING + VLM PROMPT TUNING (rolling summarization)

### What This Solves
How users correct mistakes and the app learns their personal standards over time.

### Architecture
```
User corrects a photo (taps "wrong" / "should have been hidden")
    ↓
VLM describes the photo: "Person wearing hoodie with hood up, jeans"
    ↓
Store in local DB: description + label (MODEST/NOT_MODEST)
    ↓
Next classification:
    VLM prompt includes recent corrections as examples
    ↓
Every ~10 new corrections:
    VLM summarizes all corrections into compact rules
```

### Rolling Summarization Pattern
```
Corrections 1-10:  send raw in VLM prompt
                        ↓
Hit 10 → VLM summarizes all 10 → Summary A
                        ↓
Corrections 11-20: prompt = Summary A + new raw corrections (11-20)
                        ↓
Hit 10 new → VLM summarizes (Summary A + corrections 11-20) → Summary B
                        ↓
Corrections 21-30: prompt = Summary B + new raw corrections (21-30)
                        ↓
...and so on forever
```

Prompt is always: **one summary + up to 10 raw corrections**. Never grows unbounded. Summary compresses history, raw corrections keep recent context fresh.

### How VLM Describes Corrections
When user corrects a photo, VLM runs twice:
1. **Description prompt**: "Describe what this person is wearing on their head and body" → generates text description
2. (At classification time) **Classification prompt**: includes stored descriptions as examples

User never types anything — just taps correct/wrong.

### Threshold Tuning
Separate from prompt tuning — adjusts numerical confidence thresholds per person:
- User keeps marking "too sensitive" → raise threshold (hide less)
- User keeps marking "missed this" → lower threshold (hide more)
- Simple number adjustment, no VLM involved

### Storage
Local database (CoreData/SQLite):
```
Corrections Table:
│ person │ photo_id │ vlm_description              │ label      │ timestamp │
│ Sarah  │ IMG_4021 │ hoodie with hood up, jeans    │ MODEST     │ 2026-03-01│
│ Sarah  │ IMG_4035 │ tank top, shorts              │ NOT_MODEST │ 2026-03-02│
│ Sarah  │ IMG_4078 │ bandana, long sleeve dress    │ MODEST     │ 2026-03-05│

Summaries Table:
│ person │ summary_text                                     │ version │
│ Sarah  │ "Hoodies and bandanas count as covered. Arms..." │ 3       │
```

### Options Considered
| Option | How it learns | Complexity | Verdict |
|--------|---------------|------------|---------|
| Threshold tuning only | Adjusts number cutoffs | Dead simple | Partial — included |
| CoreML MLUpdateTask (retrain) | Updates neural network weights on-device | Complex | Deferred to future |
| kNN head | Stores embeddings, nearest neighbor lookup | Needs separate clothing feature extractor | Deferred — not worth extra model for v1 |
| Prompt tuning only | Changes VLM prompt text | Simple | Partial — included |
| **Threshold + Prompt tuning (rolling)** | Numbers + text rules + examples | Moderate | **CHOSEN** |

### Why NOT kNN for v1
- kNN head needs to attach to a feature extractor that encodes clothing/appearance
- InsightFace/CLIP-ReID embeddings encode identity, not clothing style
- Would need an additional clothing-specific model just to make kNN work
- Prompt tuning achieves similar personalization without extra model
- Can add later with a clothing feature extractor if needed

---

## Decision 8: App UX — PER-PERSON FILTERS + AUTH TOGGLE + CUSTOM PROMPTS

### How The App Works
1. App is a photo viewer (reads Apple Photos via PhotoKit)
2. Photos NEVER move — they stay in Apple Photos library
3. Toggle ON = configured photos hidden from app view
4. Toggle OFF = see everything (requires FaceID/passcode/PIN)
5. Manual photo selection — user can mark any photo to be hidden
6. Filter prompt is customizable per person/group

### Per-Person Configuration
```
Configured People:
┌─────────┬──────────────────────────────────────────┐
│ Sarah   │ Filter: "not wearing hijab" (default)    │
│ Mom     │ Filter: "not wearing hijab" (default)    │
│ Brother │ Filter: ALWAYS HIDE (all photos)         │
│ Ex      │ Filter: ALWAYS HIDE (all photos)         │
│ Dad     │ Filter: "smoking or drinking" (custom)   │
└─────────┴──────────────────────────────────────────┘
```

### Groups
```
Groups:
┌──────────────┬────────────────────────┬─────────────────┐
│ "Family Women"│ Sarah, Mom, Aunt      │ default prompt  │
│ "Hide Always" │ Brother, Ex           │ ALWAYS HIDE     │
│ "Custom"      │ Dad                   │ "smoking"       │
└──────────────┴────────────────────────┴─────────────────┘
```

### Three Filter Modes
1. **Default prompt** — user-editable global default (starts as modesty check)
2. **Custom prompt** — per-person/group override with any criteria
3. **Always hide** — skip AI, hide ALL photos of this person

### Security
- Revealing hidden photos requires FaceID / passcode / PIN
- The auth protects the toggle, not the photos themselves
- Photos are never encrypted or moved — just filtered from view

---

## Decision 9: Monetization — FREE FOR NOW

Free for now. Will figure out monetization later. On-device processing means near-zero ongoing costs (no servers), so there's no urgency.

---

## Decision 11: Development Setup — NO MAC BUILD, CLOUD CI + SIDESTORE

### Problem
Developer Mac is too old to run modern Xcode. Need a way to build, sign, and test a native Swift iOS app without local Xcode.

### Chosen Approach
1. **Write Swift locally** in VS Code + Swift Extension (SourceKit-LSP) — works on any machine
2. **Build via GitHub Actions** on macOS runners — repo is **public** so builds are **free and unlimited**
3. **Install on iPhone via SideStore** — free, auto-refreshes, no computer needed day-to-day after initial setup
4. **Apple Developer Program ($99/yr)** — deferred to future (needed for TestFlight/App Store, not for personal testing)

### Why Public Repo
- GitHub Actions macOS runners are **unlimited and free** for public repos
- Private repos get only ~200 effective macOS minutes/month (10x multiplier on 2,000 free Linux minutes)
- Haya has no proprietary logic worth hiding — the value is in the trained models and user data, not the code

### Why SideStore (not AltStore/Sideloadly)
- One-time computer setup, then fully autonomous on-device
- Auto-refreshes the 7-day signing limit via on-device VPN trick
- No need to keep a companion app running on a PC
- Free Apple ID is sufficient (3-app limit, 7-day cycle managed by SideStore)

### Why NOT Apple Developer Program Now
- $99/yr buys: TestFlight (90-day builds), App Store, push notifications, 1-year provisioning
- Not needed for personal testing — SideStore handles it
- Will get it when ready to share with beta testers or publish

### Cloud Build Alternatives Evaluated
| Service | Free Tier | Verdict |
|---|---|---|
| **GitHub Actions (public repo)** | Unlimited macOS minutes | **CHOSEN** |
| GitHub Actions (private repo) | ~200 macOS min/month | Too tight |
| Codemagic | 500 macOS M2 min/month | Best if private repo needed |
| Bitrise | ~1-3 builds/month | Skip |
| EAS Build | 15 builds/month | React Native only |

### Sideloading Options Evaluated
| Method | Computer Needed? | Auto-Refresh? | Verdict |
|---|---|---|---|
| **SideStore** | Initial setup only | Yes (on-device) | **CHOSEN** |
| Sideloadly | Yes (USB/Wi-Fi) | Daemon-based | Backup option |
| AltStore | Yes (AltServer running) | Via companion | More hassle |
| TrollStore | No | No expiry | iOS 16.7 and below only |
| TestFlight | No | 90-day builds | Requires $99/yr |

### Limitations Accepted
- **No SwiftUI previews** — Xcode-only, no alternative exists
- **No local builds** — every iteration requires a CI build (~15-40 min round trip)
- **CoreML/SwiftUI/UIKit don't compile on Linux** — can only write and lint locally, must build in CI
- **xtool** (Linux→iOS build tool) can't handle binary frameworks yet — blocks CoreML, not viable today

---

## Full ML Pipeline Summary

```
STEP 1: PERSON DETECTION ("where are people?")
┌─────────────────────────────────────────────────┐
│ Apple Vision VNDetectFaceLandmarks → faces       │
│ YOLO11n-seg CoreML → full bodies (any angle)      │
│ iOS 17+: VNGeneratePersonInstanceMask → segments │
│                                                   │
│ Tight crop selection (personBox):                 │
│ ├─ mask-tight (YOLO seg mask, Python only)       │
│ ├─ face-anchored (estimated from face box)       │
│ └─ yolo_raw (raw YOLO bounding box)              │
│                                                   │
│ Multi-person handling:                            │
│ ├─ Count face centroids per body box             │
│ ├─ If >1 face → try face-anchored estimate       │
│ ├─ If estimate is cleaner (≤1 face) → use it     │
│ └─ Otherwise → keep original box                 │
│                                                   │
│ Speed: <5ms  |  Runs on: ALL photos             │
└─────────────────────────────────────────────────┘
                    ↓
STEP 2: PERSON IDENTIFICATION ("who is this?")
┌─────────────────────────────────────────────────┐
│ InsightFace ArcFace → 512-dim face embedding     │
│ CLIP-ReID ViT-B/16 → 512-dim body embedding     │
│ Temporal clustering → time/location grouping     │
│ Compare to stored centroids (cosine similarity)  │
│ Uses personBox for body crop (tight crop)        │
│                                                   │
│ 3 matching pathways:                              │
│ ├─ Face >= 0.35 → MATCH (biometric)             │
│ ├─ Wrong face + Body >= 0.90 → MATCH (override) │
│ └─ No face + Body >= 0.80 → MATCH (body only)   │
│                                                   │
│ Speed: ~15ms  |  Runs on: each detected person   │
└─────────────────────────────────────────────────┘
                    ↓
STEP 3: FILTER CHECK ("should this be hidden?")
┌─────────────────────────────────────────────────┐
│ If "ALWAYS HIDE" → HIDE (skip all ML)            │
│                                                   │
│ Layer 1: Hair Seg (<5ms)                         │
│ ├─ Lots of hair visible → HIDE (skip VLM)        │
│ └─ Otherwise → Layer 2                           │
│                                                   │
│ Layer 2: VLM SmolVLM2-2.2B/256M (200-500ms)     │
│ → Custom or default prompt with user corrections  │
│ ├─ Confident match → HIDE                        │
│ ├─ Confident no match → KEEP                     │
│ └─ Unsure → FLAG for manual review               │
│                                                   │
│ Speed: 5-500ms  |  Runs on: configured people    │
└─────────────────────────────────────────────────┘
                    ↓
STEP 4: FEEDBACK LOOP (ongoing)
┌─────────────────────────────────────────────────┐
│ User corrects mistakes → stored in local DB      │
│ VLM describes correction → text rule extracted   │
│ Rolling summarization every 10 corrections       │
│ Prompt = summary + recent raw corrections        │
│ Threshold tuning per person                      │
└─────────────────────────────────────────────────┘
```

### Model Sizes (Total on-device)
| Model | Size | Purpose |
|-------|------|---------|
| YOLO11n-seg | ~10MB | Body detection + segmentation |
| InsightFace ArcFace | ~85MB FP16 | Face embeddings |
| CLIP-ReID ViT-B/16 (INT4) | ~45-50MB | Body re-identification |
| MediaPipe Hair Seg | ~1MB | Hair pre-filter |
| SmolVLM2-2.2B (4-bit) | ~1.2GB | Modesty assessment |
| **Total** | **~1.35GB** | |

SmolVLM2-256M fallback: ~550MB total instead.

---

## Decision 10: VLM Model Switch — SmolVLM2 → FastVLM → Qwen3-VL-2B

### VLM Evolution
1. **SmolVLM2-2.2B** (Round 12-17): 61% Q1 accuracy (25/41 KEEP). CoreML blocked (unfold op).
2. **Apple FastVLM-1.5B** (Round 18): 61% Q1 accuracy (27/44 KEEP). Hallucinated arms/hair (6/10 false HIDEs = Q2 Arms).
3. **Qwen3-VL-2B-Instruct** (Current): Strongest small VLM (DocVQA 96.5). 4-bit NF4 on T4.

### Model Comparison
| Model | Q4 Size | DocVQA | Our Q1% | iPhone Path | Status |
|-------|---------|--------|---------|-------------|--------|
| SmolVLM2-2.2B | ~1.2GB | ~70 | 61% | CoreML BLOCKED | Replaced |
| Apple FastVLM-1.5B | ~1.5GB | 51.0 | 61% | CoreML native | Replaced (hallucinations) |
| Qwen2.5-VL-3B | 1.93GB | 93.9 | 83% | llama.cpp fork | Proven in R13 |
| **Qwen3-VL-2B** | 1.56GB | **96.5** | TBD | Official GGUF | **Current** |

### Qwen3-VL-2B Setup (T4 GPU)
- **Class**: `Qwen3VLForConditionalGeneration` + `AutoProcessor`
- **Quantization**: BitsAndBytes 4-bit NF4 + double quant, `bnb_4bit_compute_dtype=torch.float16`
- **Attention**: SDPA (NOT flash_attention_2 — FA2 needs SM80+, T4 is SM75)
- **Resolution**: Dynamic via `max_pixels=640*28*28` (~500K px), no manual resize
- **torch.compile**: Skip — breaks Qwen3-VL custom rotary embedding ops
- **Generation**: Greedy first (`do_sample=False`), retry with temperature bump
- **Stop criteria**: StopOnVerdict (min_tokens=15, then halt on YES/NO)
- **max_new_tokens**: 60 (reasoning + verdict)
- **Dependencies**: `transformers bitsandbytes qwen-vl-utils`

### Prompting: 1 Combined Question (Coverage-Confirmation)
- Single question covering hair/arms/legs/fit/torso (5→1Q, faster)
- YES = all covered/safe (KEEP), NO = any violation (HIDE)
- Negative anchors: "shadows, wrinkles, fabric texture are NOT bare skin"
- "THIS person only" anchoring for multi-person crops
- System prompt defaults unsure/out-of-frame to YES (covered)
- If 1Q accuracy is bad, fall back to 3Q (hair, arms, legs)

### iPhone Deployment Path
- llama.cpp + GGUF Q4_K_M (~1.5GB)
- Estimated ~5-10s/question on iPhone 13+
- Qwen3.5 NOT viable (smallest 27B dense)
- MobileVLM V2 NOT worth it (weaker than FastVLM)

### Minimum Device Requirements
- iPhone 12+ (iOS 16+) for pipeline without VLM
- iPhone 13+ recommended for Qwen3-VL-2B on-device
- iOS 17+ for best Apple Vision features

---

## Gemini Conversation Corrections

Several claims from the user's prior Gemini conversation were researched and debunked:

| Gemini Claim | Reality | Impact |
|-------------|---------|--------|
| "Piggyback off Apple's native photo clustering" | No API exists for third-party apps to access Apple's clustering | Cannot use — must build own identification |
| "ML Kit does face recognition" | ML Kit does face DETECTION only, no embeddings/recognition | Cannot use for person identification |
| "Apple Vision Framework does recognition" | Apple Vision does detection + landmarks only, no recognition | Cannot use for person identification |
| "Use Moondream2 on-device iPhone" | No proven iPhone deployment | Risky — use SmolVLM2 instead |
| "Use Qwen2-VL on-device iPhone" | No proven iPhone deployment, too large | Risky — use SmolVLM2 instead |
| "Use PaliGemma on-device iPhone" | No proven iPhone deployment | Risky — use SmolVLM2 instead |
| "Firebase ML Kit solves this" | ML Kit is detection-only, doesn't solve identification or modesty | Misleading — need multiple specialized models |

### What Gemini Got Right
- On-device processing is the right approach for privacy
- YOLO is good for person detection
- Face detection as a starting point is correct
- Feedback loop concept is valuable
- The general problem decomposition (detect → identify → classify) was correct

---

## Key Technical Concepts Explained

### ML Model Types
- **CNN (Convolutional Neural Network)**: Sliding-window filter-based image processing. YOLO, MobileNet are CNNs. Good for detection and classification.
- **Transformer/ViT**: Patch-based self-attention for global image understanding. KPR uses Swin Transformer. More accurate but heavier.
- **CLIP (Contrastive Language-Image Pre-training)**: Bridges vision + language. MobileCLIP is Apple's mobile variant. Can classify images using text descriptions.
- **VLM (Vision Language Model)**: LLMs that can see images. Understand context, can answer questions about images in natural language.

### Embeddings
Fixed-length number vectors (e.g., 512 floats) that represent an image. Two images of the same person produce similar vectors. Compare using cosine similarity (0-1 scale). Industry standard for recognition/matching.

### Enrollment (Adding a Person)
User selects 5+ photos of a person → extract face/body embeddings from each → average into centroids → store. New photos compared against stored centroids. Averaging (not fine-tuning) is industry standard for few-shot enrollment.

### Cascade Classification
Layered approach: cheap/fast model first, expensive/smart model last. Only escalate when confidence is low. Industry standard pattern for cost-effective ML pipelines.

### On-Device Processing
All ML runs on the iPhone's Neural Engine / GPU. No server calls. Photos never leave the device. CoreML is Apple's framework for running models on-device.

---

## Technology Stack Summary

| Component | Technology |
|-----------|-----------|
| Language | Swift |
| UI Framework | SwiftUI |
| ML Runtime | CoreML + Apple Neural Engine |
| Vision APIs | Apple Vision Framework |
| Photo Access | PhotoKit |
| Object Detection | YOLO11n (CoreML) |
| Face Recognition | InsightFace ArcFace (CoreML) |
| Body Re-ID | CLIP-ReID ViT-B/16 (CoreML INT4) |
| Hair Segmentation | MediaPipe Hair Seg (TFLite → CoreML) |
| VLM (Colab/Kaggle POC) | Qwen3-VL-2B-Instruct (4-bit NF4, 1Q combined) |
| VLM (iOS target) | Qwen3-VL-2B GGUF Q4_K_M via llama.cpp |
| NSFW Pre-filter | Apple SensitiveContentAnalysis (iOS 17+) |
| On-Device Learning | VLM prompt tuning + threshold adjustment |
| Local Storage | CoreData or SQLite |
| Authentication | LocalAuthentication (FaceID/TouchID/Passcode) |
| Minimum iOS | 16+ (graceful degradation for Vision features) |
| Target Devices | iPhone 12+ (256M) / iPhone 13+ (2.2B) |
