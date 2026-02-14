# YomiLingo

> **This project has been discontinued.** Development was halted during Phase 1 (early stage). The codebase is archived here for reference only and is no longer maintained.

---

## What is YomiLingo?

YomiLingo는 한국어-일본어 이중 언어 학습을 위한 iOS 앱 프로젝트입니다. 카메라로 실시간 텍스트를 인식하고 학습 오버레이(번역, 후리가나, 발음, 난이도)를 표시하는 것을 목표로 했습니다.

- **일본어 학습 모드** — 한국인을 위한 일본어 학습 (한자 후리가나, JLPT 레벨)
- **한국어 학습 모드** — 일본인을 위한 한국어 학습 (발음 표시, TOPIK 레벨)

## Implementation Status

### Completed (Core Camera Translation)

| Feature | Description |
|---------|-------------|
| Real-time OCR | Vision Framework 기반, CJK 최적화 텍스트 인식 |
| On-device Translation | iOS 18 Translation Framework, 오프라인 언어팩 지원 |
| Text Tracking | 다중 프레임 시간적 융합, 품질 점수 기반 노이즈 필터링 |
| 2D Translation Overlay | 적응형 박스 오버레이, 세로 텍스트 지원 |
| ARKit 3D Overlay | RealityKit 기반 3D 텍스트 배치 (실험적) |
| OCR Error Recovery | CJK 문자 오인식 보정, 다중 후보 융합 |
| Captured Image Translation | 캡처 이미지 고품질 OCR 및 번역 |

### Not Implemented (Planned Learning Features)

- FuriganaService — 한자 위 후리가나 표시
- PronunciationService — 한글 발음 가이드
- VocabularyManager — 단어장 저장/관리
- LevelTaggingService — JLPT/TOPIK 난이도 태깅
- SpacedRepetitionEngine — 간격 반복 학습
- ProgressTracker — 학습 통계/진도

## Tech Stack

- **Swift 5.0** / **iOS 18.0+**
- Native frameworks only (no third-party dependencies):
  - Vision, Translation, ARKit, RealityKit, AVFoundation, Metal, CoreImage, NaturalLanguage, SwiftUI, Combine

## Project Structure

```
YomiLingo/
├── App/            # AppState, RootView (entry point)
├── Camera/         # CameraManager, CameraView
├── Services/       # OCR, Translation, TextRecovery, LanguagePack, Localization
├── Tracking/       # TextTracker, ARKit/Vision tracking, scene detection
├── Views/          # Translation overlays, Settings, Debug
└── Utils/          # Logger, Metal helpers, thread safety
```

## Documentation

- `DEVELOPMENT_PLAN.md` — 개발 로드맵 (Korean)
- `ARCHITECTURE_REVIEW.md` — 아키텍처 심층 분석
- `CRITICAL_REVIEW.md` — 코드 리뷰 (41개 이슈 분석)
- `CLAUDE.md` — Claude Code 개발 가이드

## Build

```bash
xcodebuild -project YomiLingo.xcodeproj -scheme YomiLingo -sdk iphoneos build
```

Requires Xcode with iOS 18.0+ SDK. Camera features require a physical device.

## License

This project is not licensed for reuse. All rights reserved.
