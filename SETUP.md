# Haya MVP — Setup Guide

## Prerequisites

- macOS with **Xcode 16+** installed
- Physical **iPhone** (iOS 18+, A14+ chip) — simulator won't work for MLX or Vision masks
- **Python 3.11** (for model conversion scripts, already done)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Quick Start

### 1. Generate Xcode Project

```bash
cd /path/to/haya
xcodegen generate
```

This reads `project.yml` and creates `Haya.xcodeproj`.

### 2. Open in Xcode

```bash
open Haya.xcodeproj
```

### 3. Verify Models

The project references these models from `models/`:
- `ArcFace.mlpackage` (83MB) — face embeddings
- `OSNet.mlpackage` (0.7MB) — body embeddings
- `YOLO11n.mlpackage` (5.2MB) — person detection
- `hair_segmenter.tflite` (763KB) — hair segmentation

If models are missing, regenerate them:
```bash
source .venv/bin/activate
python scripts/convert_arcface.py
python scripts/convert_osnet.py
python scripts/export_yolo.py
python scripts/download_hairseg.py
```

### 4. Build & Run

1. Select your physical iPhone as the build target
2. Set your development team in Signing & Capabilities
3. Build (Cmd+B) — SPM will download mlx-swift-lm (~2-3 min first time)
4. Run (Cmd+R)

### 5. First Launch

1. Grant photo library access when prompted
2. Wait for models to load (VLM downloads ~500MB from HuggingFace on first launch)
3. Go to "People" tab → enroll a person with 5+ photos
4. Go to "Status" tab → "Run Pipeline on Photo" to test
5. Use eye icon in toolbar to toggle hidden photo visibility (FaceID protected)

## Architecture

```
Photo → Detect People (Apple Vision faces + YOLO11n bodies)
      → Identify Person (ArcFace face + OSNet body embeddings)
      → Hair Seg pre-filter (skip VLM if hair clearly visible)
      → VLM Modesty Check (SmolVLM2 via MLX Swift)
      → HIDE or KEEP
```

## Project Structure

```
Haya/
├── App/              — App entry point and main navigation
├── ML/               — All ML pipeline components
│   ├── PersonDetector.swift      — Vision + YOLO11n
│   ├── PersonIdentifier.swift    — ArcFace + OSNet
│   ├── HairSegmenter.swift       — Hair visibility pre-filter
│   ├── VLMService.swift          — SmolVLM2 via MLX Swift
│   └── Pipeline.swift            — Orchestrator
├── Views/            — SwiftUI views
│   ├── PhotoGridView.swift       — Photo library grid
│   ├── PhotoDetailView.swift     — Single photo + detection overlay
│   ├── EnrollmentView.swift      — Enroll people
│   └── ResultsView.swift         — Pipeline results display
└── Utilities/        — Shared helpers
    ├── EmbeddingMath.swift       — Cosine similarity via vDSP
    ├── FaceAligner.swift         — 5-point face alignment for ArcFace
    └── VisionCoordinates.swift   — Vision ↔ SwiftUI coordinate conversion
```

## Key Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| mlx-swift-lm | SPM | SmolVLM2 inference |
| ArcFace.mlpackage | CoreML | Face embeddings (512-dim) |
| OSNet.mlpackage | CoreML | Body embeddings (512-dim) |
| YOLO11n.mlpackage | CoreML | Person body detection |
| hair_segmenter.tflite | Bundle | Hair segmentation pre-filter |

## Entitlements

- **Increased Memory Limit** — required for VLM inference
- **Outgoing Network** — required for HuggingFace model download

## Troubleshooting

- **"Model not found" crash**: Ensure models are added to the Xcode project target
- **VLM download slow**: First launch downloads ~500MB; subsequent launches use cache
- **Memory crash**: The app auto-selects SmolVLM2-256M on devices with <3GB available RAM
- **Face alignment issues**: Check that Vision landmarks are returning 5-point constellation
