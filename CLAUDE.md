# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

YomiLingo is an iOS app for bilingual language learning between Japanese and Korean. It uses real-time camera OCR to recognize text and display learning overlays (translations, furigana, pronunciation, difficulty levels). Originally migrated from ViewLingo-Cam.

**Two learning modes:** Japanese for Korean speakers, Korean for Japanese speakers.

## Build & Run

This is a native Xcode project (no SPM dependencies, no CocoaPods).

```bash
# Build from command line
xcodebuild -project YomiLingo.xcodeproj -scheme YomiLingo -sdk iphoneos build

# Run tests
xcodebuild -project YomiLingo.xcodeproj -scheme YomiLingo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test
xcodebuild -project YomiLingo.xcodeproj -scheme YomiLingo -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:YomiLingoTests/YomiLingoTests test
```

**Requirements:** Xcode with iOS 18.0+ SDK, Swift 5.0. Camera features require a physical device.

## Architecture

The app uses **MVVM with ObservableObject** and a **centralized AppState** pattern. Key layers under `YomiLingo/`:

- **App/** — `AppState.swift` (global state: language selection, AR mode, settings), `RootView.swift` (entry point)
- **Services/** — Core business logic, each service is an `ObservableObject`:
  - `OCRService` — Vision Framework OCR with CJK-optimized text recognition
  - `TranslationService` — iOS 18 Translation Framework wrapper with session management
  - `TranslationCoordinator` — Orchestrates translation flow: language detection → session routing → caching
  - `TextRecovery` — Post-OCR error correction for CJK characters
  - `LanguagePackService` — Tracks on-device language pack availability
  - `LocalizationService` — UI string localization (static `L()` method)
  - `DynamicLanguagePackProvider` — Lazy language pack loading
- **Camera/** — `CameraManager` (AVFoundation capture pipeline), `CameraView` (main camera UI)
- **Tracking/** — Text tracking and AR rendering:
  - `TextTracker` — Multi-observation temporal fusion, quality scoring, noise filtering
  - `ARKitTracker` / `AR3DTextManager` — ARKit-based 3D text placement
  - `VisionTracker` — Vision-based 2D text tracking
  - `SceneChangeDetector` / `MotionTracker` — Scene stability and motion analysis
- **Views/** — SwiftUI views: `BoxTranslationOverlay` (standard mode), `ARKitOverlayView` (ARKit mode), `CapturedImageView` (photo editing), `SettingsView`
- **Utils/** — `Logger` (file-based debug logging), `CIContextHelper` (Metal GPU processing), thread-safety helpers

## Key Frameworks (all native, no third-party dependencies)

- **Vision** — OCR text recognition
- **Translation** — On-device translation (iOS 18+ API, `@available(iOS 18.0, *)` guards required)
- **ARKit / RealityKit** — 3D spatial text rendering
- **AVFoundation** — Camera capture
- **Metal / CoreImage** — GPU image processing
- **NaturalLanguage** — Language detection
- **SwiftUI + Combine** — UI and reactive state

## AR Modes

Two modes selectable via `AppState.arMode`:
- **Standard** — 2D screen-coordinate overlays with motion prediction and smoothing
- **ARKit** — 3D spatial AR using RealityKit (experimental, higher battery usage)

## Translation Pipeline

OCR text → `NLLanguageRecognizer` language detection → skip if same as target → route to appropriate `TranslationSession` → cache result → display overlay. The `TranslationCoordinator` manages this flow. Translation sessions are scoped to `translationTask` and not stored as instance properties.

## Conventions

- All services and `AppState` are `@MainActor`
- `#if DEBUG` guards for file logging and debug features
- Localized UI strings go through `LocalizationService.L()` — supports ko, en, ja, fr
- Development plan and notes are in Korean (see `DEVELOPMENT_PLAN.md`)
- Test guides in `YomiLingo/Testing/` cover manual camera and AR testing scenarios

## Development Status

Early stage — Phase 1 (restructuring for learning app). Planned features not yet implemented: FuriganaService, PronunciationService, VocabularyManager, LevelTaggingService (JLPT/TOPIK), SpacedRepetitionEngine, ProgressTracker. See `DEVELOPMENT_PLAN.md` for the full roadmap.
