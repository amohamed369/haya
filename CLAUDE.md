# Haya — Project Instructions

## Build Environment (CRITICAL)

- **NO local Xcode** — dev Mac runs macOS 12 Monterey, too old for modern Xcode
- **Build ONLY via GitHub Actions CI** — commit and push, CI builds the .ipa
- **NEVER run xcodegen, xcodebuild, or swift build locally** — they will fail
- Install on iPhone via AltStore/SideStore (7-day signing)
- Project config: `project.yml` → XcodeGen → xcodebuild (all in CI)

## iOS 26.3 Beta

- ANECompiler has a SIGSEGV bug — use `computeUnits = .cpuAndGPU` not `.all`
- Can revert to `.all` when Apple fixes the ANE bug in a future release

## Architecture

- Native SwiftUI iOS 18+ app
- ML pipeline: PersonDetector (Vision+YOLO) → PersonIdentifier (ArcFace+CLIPReID) → HairSegmenter → VLMService (Qwen3.5-4B via MLX Swift)
- All ML models are actors for thread safety
- Pipeline is @MainActor ObservableObject
- LogStore.shared: @MainActor singleton, injected as environmentObject

## Design System

- Theme: HayaTheme.swift (tokens), HayaFonts.swift (typography), GlassModifiers.swift (components)
- Aesthetic: neoglassmorphism + soft neobrutalism — NO glowing, NO pulsing
- Crisp offset shadows, gradient borders (light from top-left), snappy spring animations
