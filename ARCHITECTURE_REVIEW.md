# YomiLingo 아키텍처 심층 분석 문서

> 분석일: 2026-02-14
> 분석 범위: 전체 소스 코드 (30개 Swift 파일, 테스트 3개, 문서 3개)
> 프로젝트 상태: Phase 1 초기 (ViewLingo-Cam에서 학습 앱으로 전환 중)

---

## 1. 전체 아키텍처 개요

### 1.1 레이어 다이어그램

```
┌──────────────────────────────────────────────────────────────────┐
│                        앱 진입점 (App Layer)                       │
│  ViewLingoCamApp ─── RootView ─── AppState (전역 상태)              │
│  [YomiLingoApp.swift, ContentView.swift - 미사용 템플릿]             │
└───────────────┬──────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────┐
│                     카메라 & UI 오케스트레이션                        │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              CameraView (~1354줄, 핵심 조율자)                 │ │
│  │  - 모든 서비스 생성 (@StateObject)                             │ │
│  │  - 프레임 처리 파이프라인 관리                                    │ │
│  │  - Live/Capture 모드 제어                                     │ │
│  │  - 언어 선택 UI (중첩 뷰)                                      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│  CameraManager (AVFoundation, 15fps)                             │
└───────────────┬──────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────┐
│                          서비스 레이어                              │
│  ┌──────────┐ ┌───────────────────┐ ┌──────────────────────────┐ │
│  │OCRService│ │TranslationCoord.  │ │  LanguagePackService     │ │
│  │  Vision  │ │ (요청 기반 번역)    │ │  (Singleton, 팩 관리)     │ │
│  │  ~900줄  │ │                   │ │                          │ │
│  └────┬─────┘ └────────┬──────────┘ └──────────────────────────┘ │
│       │                │                                         │
│  ┌────▼─────┐ ┌────────▼──────────┐ ┌──────────────────────────┐ │
│  │TextRecov.│ │TranslationService │ │  LocalizationService     │ │
│  │OCR 보정  │ │ (레거시, 세션 기반)  │ │  (정적 UI 문자열)          │ │
│  │  ~608줄  │ │    ~1073줄        │ │                          │ │
│  └──────────┘ └───────────────────┘ └──────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  DynamicLanguagePackProvider (SwiftUI .translationTask)       │ │
│  │  TranslationRequest (요청/응답 추적)                            │ │
│  └──────────────────────────────────────────────────────────────┘ │
└───────────────┬──────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────┐
│                        트래킹 레이어                               │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │             TextTracker (~1287줄, 핵심 추적 시스템)              │ │
│  │  - TrackedText 구조체 (품질 점수, 시간적 융합, 상태 머신)          │ │
│  │  - 노이즈 필터링, IoU 중복 감지, 히스테리시스                      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────────┐ │
│  │VisionTracker │ │MotionTracker │ │SceneChangeDetector       │ │
│  │Vision 객체추적│ │CoreMotion 60Hz│ │장면 변화 감지 상태 머신     │ │
│  └──────────────┘ └──────────────┘ └──────────────────────────┘ │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────────┐ │
│  │ARKitTracker  │ │ARFrameProc.  │ │AR3DTextManager (~1414줄) │ │
│  │ARKit 세션 관리│ │AR 프레임 OCR  │ │3D 텍스트 엔티티 관리       │ │
│  └──────────────┘ └──────────────┘ └──────────────────────────┘ │
└───────────────┬──────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────┐
│                         뷰 레이어                                 │
│  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐ │
│  │BoxTranslation    │ │ARTranslation     │ │ARKitOverlayView  │ │
│  │Overlay (~896줄)  │ │Overlay           │ │(UIViewRepresent.)│ │
│  │2D 오버레이 (메인)  │ │레거시/하이브리드    │ │3D AR 뷰          │ │
│  └──────────────────┘ └──────────────────┘ └──────────────────┘ │
│  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐ │
│  │CapturedImageView │ │SettingsView      │ │DebugView         │ │
│  │캡처 이미지 번역    │ │설정 화면          │ │디버그 (#if DEBUG) │ │
│  └──────────────────┘ └──────────────────┘ └──────────────────┘ │
└───────────────┬──────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────┐
│                        유틸리티 레이어                              │
│  Logger (파일/콘솔/OS 로깅)  │  CIContextHelper (Metal GPU)       │
│  AtomicInt (스레드 안전)     │  UnsafeSendable (CVPixelBuffer)    │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 파일 규모 분포

| 파일 | 줄 수 | 복잡도 | 역할 |
|-----|------|-------|------|
| `CameraView.swift` | ~1354 | **매우 높음** | 전체 오케스트레이터 |
| `AR3DTextManager.swift` | ~1414 | **매우 높음** | 3D 텍스트 관리 |
| `TextTracker.swift` | ~1287 | **높음** | 텍스트 추적 핵심 |
| `TranslationService.swift` | ~1073 | **높음** | 레거시 번역 서비스 |
| `OCRService.swift` | ~900 | **높음** | OCR 엔진 |
| `BoxTranslationOverlay.swift` | ~896 | **중간** | 2D 오버레이 렌더링 |
| `ARKitOverlayView.swift` | ~646 | **중간** | ARKit 뷰 래퍼 |
| `TextRecovery.swift` | ~608 | **중간** | OCR 텍스트 보정 |
| `CapturedImageView.swift` | ~649 | **중간** | 캡처 이미지 처리 |
| `SettingsView.swift` | ~537 | **중간** | 설정 화면 |
| 나머지 16개 파일 | 각 ~20-300 | 낮음-중간 | 보조 기능 |

---

## 2. 모듈별 상세 분석

### 2.1 앱 진입점 (App Layer)

#### ViewLingoCamApp.swift (실제 진입점)
- `@main` 어노테이션으로 앱 시작점
- `AppState`를 `@StateObject`로 생성, `.environmentObject`로 전파
- iOS 18.0 가용성 체크 (`@available(iOS 18.0, *)`)
- 미지원 버전에 대한 `UnsupportedVersionView` 표시

#### YomiLingoApp.swift + ContentView.swift (미사용)
- Xcode 프로젝트 생성 시 자동 생성된 템플릿 파일
- `@main` 어노테이션 포함 — **빌드 타겟에서 제외되어야 함**
- "Hello, world!" 만 표시하는 빈 ContentView

> **문제점**: 두 개의 `@main` 구조체가 존재. 빌드 설정에서 하나만 활성화되어 있겠지만, 프로젝트 정리가 필요.

#### AppState.swift (전역 상태 관리)
- `@MainActor ObservableObject` — 앱 전체 공유 상태
- **관리하는 상태**:
  - `targetLanguage` (ko/en/ja) — 번역 대상 언어
  - `sourceLanguage` — 인식 소스 언어
  - `arMode` (.standard/.arkit) — AR 모드 선택
  - `isLiveTranslationEnabled` — 실시간 번역 활성화
  - `enabledSourceLanguages` — 활성화된 소스 언어 집합
- `UserDefaults` 기반 영속화 (Combine `sink`로 자동 저장)
- 시스템 로케일 기반 최적 대상 언어 자동 감지
- `availableSourceLanguages` 계산 프로퍼티 (fr 포함 확장)

#### RootView.swift
- 최소 구성 — `CameraView` 직접 표시
- 선택적 `DebugView` 시트 (#if DEBUG)

### 2.2 카메라 레이어

#### CameraManager.swift
- `@MainActor ObservableObject`
- AVFoundation 기반 카메라 캡처 파이프라인
- **사양**: 15fps, BGRA 픽셀 포맷, 1920x1080
- `currentFrame` (CVPixelBuffer)과 `frameUpdateCount` 퍼블리시
- `AtomicInt` 사용하여 스레드 안전한 프레임 카운팅
- start/stop/pause/resume 생명주기 관리

#### CameraView.swift (~1354줄) — **핵심 오케스트레이터**
- **모든 서비스를 @StateObject로 생성**:
  - `cameraManager`, `ocrService`, `translationCoordinator`
  - `languageService`, `textTracker`, `sceneDetector`
- **주요 책임** (과도함):
  1. 프레임 수신 및 OCR 처리 파이프라인
  2. 번역 요청 및 결과 관리
  3. Live/Capture 모드 전환
  4. 언어 선택 UI 및 팩 설치
  5. AR 모드 전환 (Standard ↔ ARKit)
  6. 캡처 이미지 처리 및 표시
  7. 설정 화면 네비게이션
- **중첩 타입**: `CameraPreviewView`, `LanguageSelectorView`, `LanguageOptionRow`, `LanguageInstallationProvider`

> **심각한 문제**: God Object 안티패턴. 단일 뷰가 모든 서비스 생명주기와 비즈니스 로직을 관리. 분리 필요.

### 2.3 서비스 레이어

#### OCRService.swift (~900줄)
- Vision Framework `VNRecognizeTextRequest` 기반
- `RecognizedText` 구조체: text, confidence, boundingBox, language, isVertical
- **CJK 최적화**:
  - 극단적으로 낮은 신뢰도 임계값 (일본어/한국어: 0.01)
  - 세로 텍스트 감지 및 그룹화
  - 대상 언어 기반 인식 우선순위 조정
  - `recognitionLanguages` 동적 설정
- fast/accurate 모드 전환
- `TextRecovery` 통합하여 다중 후보 융합
- 광범위한 노이즈 필터링 (패턴, 크기, 깨진 텍스트)
- processBuffer / processImage 두 가지 진입점

#### TranslationCoordinator.swift (활성 번역 시스템)
- **요청 기반 아키텍처** — TranslationSession을 인스턴스 프로퍼티로 저장하지 않음
- `TranslationExecutor`와 `TranslationTaskView` (SwiftUI 뷰)를 통해 `.translationTask` 수정자로 세션 생성
- 동작 흐름:
  1. `detectLanguages(for:)` → NLLanguageRecognizer로 언어 감지
  2. `requestTranslation(texts:from:to:)` → 번역 요청 큐잉
  3. TranslationExecutor가 `.translationTask`를 통해 실제 번역 수행
  4. 콜백으로 결과 반환
- `installedLanguagePairs` 관리
- 내부 번역 캐시

#### TranslationService.swift (~1073줄, 레거시)
- 세션 기반 번역 (구 시스템, 아직 코드베이스에 존재)
- **풍부한 언어 감지 로직**:
  - 문자 유니코드 범위 기반 카운팅
  - 컨텍스트 힌트와 최근 감지 이력
  - NLLanguageRecognizer 폴백
  - 일본어 한자 감지 (상용한자 사전 내장)
- 번역 전/후 텍스트 클리닝
- `missingLanguagePacks` 추적

> **문제점**: TranslationCoordinator와 역할이 중복. 레거시 코드 정리 필요.

#### TextRecovery.swift (~608줄)
- OCR 후처리 텍스트 보정 시스템
- **문자 치환 규칙**: 일반 OCR 오류 (0↔O, 1↔l 등)
- **언어별 특수 보정**:
  - 일본어: 탁점(dakuten) 보정, 카타카나/히라가나 오인식
  - 한국어: 음절 보정, 자모 재조합
  - 한국어↔일본어 교차 언어 오인식 보정
- `TemporalAccumulator`: 프레임 기반 시간적 융합
- Levenshtein 거리 기반 다중 후보 융합
- `String` 확장: `hasOCRErrors`, `ocrRecovered`

#### LanguagePackService.swift (Singleton)
- Translation 프레임워크의 `LanguageAvailability` API 활용
- 팩 상태 관리: checking/installed/notInstalled/unsupported
- 세션 유효성 캐시
- 앱 포그라운드 복귀 시 상태 갱신
- 대상 언어별 필요 언어 쌍 계산

#### LocalizationService.swift
- 정적 UI 문자열 로컬라이제이션
- 하드코딩된 딕셔너리 (ko/en/ja)
- `L()` 정적 메서드로 조회
- 시스템 언어 자동 감지

#### DynamicLanguagePackProvider.swift
- SwiftUI 기반 언어 팩 관리 뷰
- `.translationTask` 수정자로 세션 생성 → `prepareTranslation()` 호출
- `BatchLanguagePackProvider`: 대상 언어에 필요한 모든 쌍 일괄 설치
- `SimpleTranslationSessionProvider`: 단일 세션 래퍼

#### TranslationRequest.swift
- 간단한 요청/응답 추적 클래스
- `pendingRequests`, `completedTranslations` 관리

### 2.4 트래킹 레이어

#### TextTracker.swift (~1287줄) — **핵심 추적 시스템**

**TrackedText 구조체** (광범위한 필드):
- 기본: id, text, boundingBox, confidence, translation
- 품질: qualityScore, suspicionLevel, bestText, bestConfidence, bestTranslation
- 시간적 융합: textHistory, confidenceHistory, observationCount
- 상태 머신: `DetectionState` (detected → translating → translated → failed)
- 히스테리시스: isOnScreen, smoothedBox
- 메타데이터: isVerticalText, sourceLanguage, isDisplayable

**TextTracker 클래스**:
- `processNewTexts()`: OCR 결과 → 기존 추적 텍스트 매칭 → 업데이트/생성
- IoU 기반 중복 감지
- Levenshtein 거리 + CJK 부스트 텍스트 유사도
- `PendingText`: 다중 프레임 확인을 통한 노이즈 필터링
- `updateTranslations()`: 번역 결과 반영
- `markTextsAsTranslating()`: 번역 중 상태 표시
- `TranslationCache` (Singleton): 번역 결과 캐시 (200개 제한)
- arMode 인식: Standard vs ARKit 모드별 다른 동작

#### VisionTracker.swift
- Vision 프레임워크의 `VNTrackObjectRequest` 기반 객체 추적
- `TrackedObject`: 초기 박스, 현재 박스, 신뢰도, 추적 상태
- `VNSequenceRequestHandler`로 프레임 간 추적
- IoU 기반 OCR 결과 동기화 (`syncWithOCRResults`)
- 광학 플로 확장 (스텁 구현)

#### MotionTracker.swift
- CoreMotion 기반 디바이스 모션 추적 (60Hz)
- 칼만 필터 (저역 통과 필터)로 노이즈 감소
- 회전 → 화면 이동 변환
- 가속도 기반 유의미 모션 감지
- 모션 예측: `getPredictedPosition`, `getPredictedPath`, `getInterpolatedPosition`

#### SceneChangeDetector.swift
- 상태 머신: stable → moving → transitioning
- **변화 점수 계산** (가중 결합):
  - 텍스트 변화 (Jaccard 거리): 0.2
  - 위치 변화 (질량 중심): 0.3
  - 신뢰도 변화: 0.1
  - 분포 변화 (사분면): 0.4
- 롤링 윈도우 평균 (5프레임)
- 히스테리시스 기반 상태 전환 방지
- `getPersistenceMultiplier()`: 상태별 오버레이 지속 시간 조절

#### ARKitTracker.swift
- ARKit 세션 관리 (`ARWorldTrackingConfiguration`)
- `TextAnchor`: ARAnchor + SIMD3 위치
- 평면 감지 없이 간단한 3D 위치 지정
- ARView 연결 및 세션 생명주기

#### AR3DTextManager.swift (~1414줄)
- RealityKit 기반 3D 텍스트 엔티티 관리
- **좌표 변환 체인**: Vision(가로, 좌하단 원점) → 화면 → ARKit 월드 좌표
- 포트레이트/랜드스케이프 지원
- Raycast 기반 배치
- 메시 캐싱으로 성능 최적화
- 거리 기반 컬링
- 플레이스홀더 → 번역된 앵커 상태 전환
- FOV 체크 기반 정리
- 디버그 시각화 (#if DEBUG)

#### ARFrameProcessor.swift
- `ARSessionDelegate` 구현
- AR 프레임을 OCR용으로 처리
- **중요**: `copyPixelBuffer`로 ARFrame 즉시 해제 (메모리 최적화)
- 시간 간격 기반 처리 (0.2초)
- `autoreleasepool` 사용

### 2.5 뷰 레이어

#### BoxTranslationOverlay.swift (~896줄) — **메인 2D 오버레이**
- **BoxTranslation** 뷰:
  - 정규화 좌표 → 화면 좌표 변환
  - 품질 점수 기반 적응형 스타일링 (테두리 색상, 투명도, 폰트 두께)
  - suspicionLevel 기반 점진적 페이드아웃
  - 세로 텍스트 지원 (일본어: 세로 레이아웃, 한국어/영어: 90도 회전)
  - 탭하면 원문/번역 전환
  - `cleanForDisplay()`: 시각적 노이즈 제거
- **FontSizeCalculator**: UIKit 기반 이진 탐색 최적 폰트 크기 계산
- **VerticalJapaneseText**: 일본어 세로 쓰기 컴포넌트 (구두점 회전, 縦中横)
- **PlaceholderBox**: 번역 대기 중 로딩 상태 표시 (펄스 애니메이션)
- 캡처 이미지/라이브 모드 Y축 보정

#### ARTranslationOverlay.swift
- 레거시/하이브리드 추적 오버레이
- `TranslationBubble`: 풍선형 번역 표시 (구 디자인)
- `DebugOverlay`: 바운딩 박스 디버그 표시
- 하이브리드 모드와 레거시 모드 분기

#### ARKitOverlayView.swift (~646줄)
- `UIViewRepresentable` — ARView를 SwiftUI에 통합
- **Coordinator 패턴**:
  - `ARFrameProcessor` 인스턴스 관리 (단일)
  - `OCRService` 인스턴스 (ARKit 전용)
  - `TextTracker` 인스턴스 (ARKit 전용)
  - 텍스트 감지 → 번역 → 3D 업데이트 파이프라인
- 디바이스 유형별 ARKit 설정 (iPad vs iPhone)
- `dismantleUIView`: 세션 정리 및 리소스 해제
- Live 모드 on/off에 따른 처리 제어

#### CapturedImageView.swift (~649줄)
- 캡처 이미지에 번역 오버레이 표시
- 핀치 줌 / 드래그 팬 / 더블탭 줌 제스처
- 고품질 OCR (accurate 모드) 수행
- 번역 재시도 로직 (`performTranslationWithRetry`)
- 컴포지트 이미지 생성 및 공유 기능 (UIGraphicsImageRenderer)
- `TranslationExecutor`를 숨겨진 백그라운드 뷰로 포함

#### SettingsView.swift (~537줄)
- 온디바이스 번역 모드 상태 표시 및 안내
- 언어팩 상태 확인 (LanguagePackService 연동)
- 소스 언어 선택 (다중 선택 가능)
- AR 모드 설정 (#if DEBUG에서만 표시)
- 앱 설정 초기화
- `LanguagePackRow`: 언어팩 상태 행 컴포넌트

#### DebugView.swift
- 탭 기반 디버그 정보 (#if DEBUG)
- 언어팩 상태, 앱 상태, 로그, 성능 정보
- 실제 메모리 사용량 측정 (`mach_task_basic_info`)
- 로그 파일 내용 표시 및 관리

### 2.6 유틸리티 레이어

#### Logger.swift
- 싱글톤 패턴
- 레벨: debug, info, warning, error
- 출력 채널: 콘솔 (print), OS 로그, 파일 (Documents/ViewLingoCam.log)
- `#if DEBUG` 가드: 릴리스에서는 error만, 파일/콘솔 로깅 비활성
- 특화 로깅: `logOnboarding`, `logLanguagePack`, `logTranslation`, `logOCR`, `logCamera`, `logPerformance`

#### CIContextHelper.swift
- Metal GPU 기반 CIContext 공유 인스턴스
- iPad 호환성 (shared storage mode)
- 소프트웨어 렌더러 폴백

#### AtomicInt.swift
- NSLock 기반 스레드 안전 정수 래퍼
- increment/get/set/reset 연산

#### UnsafeSendable.swift
- `@unchecked Sendable` 래퍼 (제네릭)
- CVPixelBuffer 등 Sendable 미준수 타입용
- Swift 6 동시성 경고 해소

---

## 3. 데이터 흐름 매핑

### 3.1 실시간 번역 파이프라인 (Live Mode - Standard)

```
카메라 프레임 (15fps)
    │
    ▼
CameraManager.currentFrame (CVPixelBuffer)
    │
    ▼ (.onChange in CameraView)
OCRService.processBuffer()
    │ ┌─ VNRecognizeTextRequest 실행
    │ ├─ CJK 최적화 인식 언어 설정
    │ ├─ 세로 텍스트 감지/그룹화
    │ └─ TextRecovery.recoverText() (다중 후보 융합)
    │
    ▼
[OCRService.RecognizedText] (text, confidence, boundingBox)
    │
    ├──▶ TextTracker.processNewTexts()
    │       ├─ 기존 TrackedText와 IoU/텍스트유사도 매칭
    │       ├─ PendingText 확인 (노이즈 필터링)
    │       ├─ 품질 점수 업데이트
    │       └─ smoothedBox 계산 (이동 평균)
    │
    ├──▶ SceneChangeDetector.analyzeFrame()
    │       └─ stable/moving/transitioning 상태 결정
    │
    └──▶ TranslationCoordinator.requestTranslation()
            ├─ NLLanguageRecognizer 언어 감지
            ├─ 소스=타겟 → 건너뛰기
            ├─ TranslationCache 확인
            └─ TranslationExecutor (.translationTask)
                    │
                    ▼
            TextTracker.updateTranslations()
                    │
                    ▼
            BoxTranslationOverlay 렌더링
                ├─ 정규화 좌표 → 화면 좌표
                ├─ FontSizeCalculator (이진 탐색)
                ├─ 품질 기반 스타일링
                └─ 세로 텍스트 레이아웃
```

### 3.2 실시간 번역 파이프라인 (Live Mode - ARKit)

```
AR 프레임 (30fps)
    │
    ▼
ARFrameProcessor.session(_:didUpdate:)
    │ ├─ autoreleasepool로 메모리 관리
    │ ├─ copyPixelBuffer() → ARFrame 즉시 해제
    │ └─ 0.2초 간격 처리 제한
    │
    ▼
OCRService.processBuffer(isARFrame: true)
    │ └─ ARKit 회전 처리
    │
    ▼
ARKitOverlayView.Coordinator.processDetectedTexts()
    │ ├─ TextTracker.processNewTexts() (별도 인스턴스)
    │ ├─ AR3DTextManager.updateTexts() (플레이스홀더)
    │ ├─ 번역 수행 (TranslationCoordinator)
    │ └─ AR3DTextManager.updateTexts() (번역 결과)
    │
    ▼
AR3DTextManager
    ├─ Vision 좌표 → 화면 좌표 → 월드 좌표 변환
    ├─ RealityKit MeshResource.generateText()
    ├─ 메시 캐싱 및 거리 기반 컬링
    └─ AnchorEntity 관리
```

### 3.3 수동 캡처 파이프라인

```
사용자 캡처 버튼 탭
    │
    ▼
CameraView → CapturedImageView 표시
    │
    ▼
OCRService.processImage() (accurate 모드)
    │
    ▼
TextTracker.processNewTexts() (arMode = .arkit로 즉시 프로모션)
    │
    ▼
waitForTranslationAndProcess()
    ├─ 언어팩 설치 대기 (최대 5초)
    └─ performTranslationWithRetry() (최대 2회)
            ├─ 언어별 그룹화 → 병렬 번역
            ├─ 동일 언어 번역 건너뛰기
            └─ 결과 필터링 (원문=번역문 제거)
    │
    ▼
BoxTranslation 오버레이 (isCapturedImage: true)
    ├─ 이미지 영역 기반 좌표 계산
    └─ 핀치 줌/드래그 팬 지원
```

### 3.4 언어팩 관리 흐름

```
앱 시작 / 언어 변경
    │
    ▼
LanguagePackService.checkAllStatuses()
    │ └─ LanguageAvailability API로 각 쌍 확인
    │
    ▼
CameraView.LanguageSelectorView
    │ └─ 대상 언어 선택 시 필요 팩 확인
    │
    ▼
DynamicLanguagePackProvider / BatchLanguagePackProvider
    │ └─ .translationTask 수정자로 세션 생성
    │     └─ prepareTranslation() → 팩 설치 트리거
    │
    ▼
LanguagePackService.packStatuses 업데이트
    └─ NotificationCenter (포그라운드 복귀 시 갱신)
```

---

## 4. 의존성 관계도

### 4.1 서비스 의존성 그래프

```
                    AppState
                   /   |    \
                  /    |     \
         CameraView  Settings  RootView
            /  |  \
           /   |   \
   OCRService  |  TranslationCoordinator ◄─── TranslationRequest
       |       |       |           \
  TextRecovery |  TranslationService  DynamicLanguagePackProvider
               |  (레거시)              |
          TextTracker              LanguagePackService (Singleton)
           /   |   \                    |
   VisionTracker  SceneChangeDetector   TranslationExecutor
                                       TranslationTaskView
          MotionTracker (독립)

   ARKitOverlayView
      |     \
  ARKitTracker  AR3DTextManager
      |             |
  ARFrameProcessor  TextTracker (별도 인스턴스)
      |
  OCRService (별도 인스턴스)
```

### 4.2 핵심 타입 의존성

```
TrackedText ◄─── TextTracker ◄─── CameraView
    |                                    |
    ├─── BoxTranslationOverlay           ├─── BoxTranslation
    ├─── ARTranslationOverlay            ├─── PlaceholderBox
    ├─── CapturedImageView               └─── VerticalJapaneseText
    └─── ARKitOverlayView

OCRService.RecognizedText ◄─── OCRService ◄─── CameraView
    |                                            |
    ├─── TextTracker                             └─── ARFrameProcessor
    ├─── SceneChangeDetector
    └─── DebugOverlay

TranslationCache (Singleton) ◄─── TextTracker
                              ◄─── ARKitOverlayView.Coordinator
```

### 4.3 문제가 있는 의존성

1. **CameraView → 모든 것**: 서비스 6개를 직접 생성하고 관리
2. **ARKitOverlayView.Coordinator**: 별도의 OCRService, TextTracker 인스턴스 생성 → 리소스 중복
3. **TranslationService (레거시) ↔ TranslationCoordinator**: 역할 중복, 둘 다 언어 감지 로직 보유
4. **LanguagePackService**: 싱글톤이면서 SettingsView와 CameraView 양쪽에서 접근
5. **TranslationCache**: 싱글톤으로 TextTracker와 ARKitOverlayView.Coordinator 양쪽에서 직접 접근

---

## 5. 현재 구현 상태

### 5.1 구현 완료 (Core)

| 기능 | 파일 | 상태 | 품질 |
|------|------|------|------|
| 카메라 캡처 파이프라인 | CameraManager | **완료** | 양호 |
| OCR 텍스트 인식 (CJK) | OCRService | **완료** | 우수 |
| OCR 텍스트 보정 | TextRecovery | **완료** | 우수 |
| 텍스트 추적/융합 | TextTracker | **완료** | 우수 |
| 온디바이스 번역 | TranslationCoordinator | **완료** | 양호 |
| 언어팩 관리 | LanguagePackService | **완료** | 양호 |
| 2D 번역 오버레이 | BoxTranslationOverlay | **완료** | 우수 |
| 캡처 이미지 번역 | CapturedImageView | **완료** | 양호 |
| 장면 변화 감지 | SceneChangeDetector | **완료** | 양호 |
| 디바이스 모션 추적 | MotionTracker | **완료** | 양호 |
| UI 로컬라이제이션 | LocalizationService | **완료** | 기본 |
| 설정 화면 | SettingsView | **완료** | 양호 |
| 디버그 도구 | DebugView, Logger | **완료** | 양호 |
| Metal GPU 처리 | CIContextHelper | **완료** | 양호 |

### 5.2 부분 구현

| 기능 | 파일 | 상태 | 비고 |
|------|------|------|------|
| ARKit 3D 오버레이 | ARKitOverlayView, AR3DTextManager | **부분 구현** | 동작하지만 실험적 (DEBUG에서만 설정 노출) |
| ARKit 추적 | ARKitTracker, ARFrameProcessor | **부분 구현** | 기본 기능 동작, 평면 감지 활용 제한적 |
| Vision 객체 추적 | VisionTracker | **부분 구현** | 광학 플로 스텁 구현만 |
| 레거시 번역 서비스 | TranslationService | **부분 구현** | 코드 존재하지만 활성 시스템은 TranslationCoordinator |
| 하이브리드 오버레이 | ARTranslationOverlay | **부분 구현** | 레거시/하이브리드 두 경로 모두 존재 |
| 테스트 | YomiLingoTests 등 | **스텁** | 빈 테스트만 존재 |

### 5.3 미구현 (DEVELOPMENT_PLAN.md 기준)

| 계획된 기능 | 상태 | 우선순위 |
|------------|------|---------|
| FuriganaService (후리가나 생성) | **미구현** | Phase 2 핵심 |
| PronunciationService (한글 발음 표시) | **미구현** | Phase 2 핵심 |
| VocabularyManager (단어장) | **미구현** | Phase 2 핵심 |
| LevelTaggingService (JLPT/TOPIK) | **미구현** | Phase 2 핵심 |
| SpacedRepetitionEngine (복습) | **미구현** | Phase 3 |
| LearningModeSelector (모드 전환 UI) | **미구현** | Phase 1 |
| ProgressTracker (학습 통계) | **미구현** | Phase 3 |
| 단어 터치 → 상세 정보 | **미구현** | Phase 2 |
| 오프라인 모드 최적화 | **미구현** | Phase 3 |

---

## 6. 설계 품질 평가

### 6.1 잘 설계된 부분

#### OCR 파이프라인 (우수)
- CJK 문자에 특화된 세밀한 최적화 (신뢰도 임계값, 세로 텍스트, 인식 우선순위)
- TextRecovery의 다중 후보 융합은 실용적이고 효과적
- 언어별 특수 보정 규칙이 실제 OCR 오류 패턴에 기반

#### 텍스트 추적 시스템 (우수)
- TrackedText의 다층적 품질 평가 (관찰 횟수, 신뢰도 이력, 품질 점수)
- PendingText를 통한 노이즈 필터링은 실시간 OCR의 핵심 문제를 잘 해결
- 히스테리시스 기반 온/오프스크린 판정으로 깜빡임 방지
- suspicionLevel을 통한 점진적 페이드아웃

#### 번역 아키텍처 (양호)
- iOS 18 `.translationTask` 수정자를 활용한 세션 관리가 Apple 권장 패턴에 부합
- 세션을 프로퍼티로 저장하지 않는 요청 기반 설계가 메모리 효율적
- 다중 소스 언어 동시 처리

#### 메모리 관리 (양호)
- ARFrameProcessor의 `copyPixelBuffer` + `autoreleasepool` 조합
- UnsafeSendable을 통한 Swift 6 동시성 호환
- AtomicInt으로 스레드 안전 보장

#### 적응형 오버레이 렌더링 (양호)
- FontSizeCalculator의 이진 탐색 알고리즘
- 품질 점수 기반 시각적 피드백 (테두리 색, 투명도, 폰트 두께)
- 일본어 세로 쓰기 전용 컴포넌트 (VerticalJapaneseText)
- 세로 박스에서 한국어/영어 자동 90도 회전

#### @MainActor 일관성 (양호)
- 모든 서비스와 상태 클래스에 @MainActor 적용
- UI 업데이트 스레드 안전성 보장

### 6.2 개선이 필요한 부분

#### CameraView God Object (심각)
- **문제**: ~1354줄, 서비스 6개 직접 생성, 모든 비즈니스 로직 포함
- **영향**: 유지보수 어려움, 테스트 불가, 코드 재사용 불가
- **권장**: ViewModel 분리 (CameraViewModel), 서비스 주입 패턴 도입

#### 레거시 코드 잔존 (중간)
- **문제**: TranslationService(~1073줄)가 레거시로 남아있으면서 TranslationCoordinator와 역할 중복
- **영향**: 혼란, 불필요한 코드 복잡성
- **권장**: TranslationService 제거 또는 통합, 언어 감지 로직 단일화

#### 서비스 인스턴스 중복 (중간)
- **문제**: ARKitOverlayView.Coordinator가 별도 OCRService, TextTracker 생성
- **영향**: 메모리 낭비, 상태 불일치 가능성
- **권장**: 서비스 공유 또는 DI 컨테이너 도입

#### 테스트 부재 (심각)
- **문제**: 모든 테스트 파일이 빈 템플릿
- **영향**: 리팩토링 안전성 없음, 회귀 버그 감지 불가
- **권장**: TextTracker, OCRService, TextRecovery 등 핵심 로직 단위 테스트 작성

#### 하드코딩된 로컬라이제이션 (낮음)
- **문제**: LocalizationService가 딕셔너리 기반, 일부 UI에 한국어 문자열 직접 사용
- **영향**: 확장성 제한, 번역 누락 가능
- **권장**: Localizable.strings로 전환 (Apple 표준)

#### 미사용 파일 잔존 (낮음)
- **문제**: YomiLingoApp.swift, ContentView.swift (빈 템플릿)
- **영향**: 프로젝트 혼란
- **권장**: 빌드 타겟에서 제거 또는 삭제

#### 에러 처리 패턴 불일치 (낮음)
- **문제**: 일부는 Logger로 기록만, 일부는 무시, 사용자에게 노출되는 에러 없음
- **영향**: 디버깅 어려움, 사용자 피드백 부재
- **권장**: 에러 전파 전략 통일

### 6.3 아키텍처 리스크

1. **단일 장애점**: CameraView가 모든 것을 오케스트레이션 → 이 뷰의 버그가 전체 앱에 영향
2. **상태 동기화**: 여러 TrackedText 인스턴스가 서로 다른 시점의 데이터를 가질 수 있음
3. **메모리 압박**: 대용량 파일(AR3DTextManager, BoxTranslationOverlay)이 복잡한 뷰 계층 생성
4. **학습 앱 전환 장벽**: 현재 구조는 "번역 앱"에 최적화되어 있어, 학습 기능 추가 시 대규모 리팩토링 필요

---

## 7. Phase 2 전환을 위한 권장 작업 목록

### 7.1 즉시 필요 (Phase 1 완성)

1. **CameraView 분리** — CameraViewModel 추출 (최우선)
2. **미사용 파일 정리** — YomiLingoApp.swift, ContentView.swift 제거
3. **TranslationService 레거시 코드 정리** — TranslationCoordinator로 통합
4. **핵심 서비스 단위 테스트 작성** — TextTracker, TextRecovery, OCRService

### 7.2 Phase 2 준비

5. **서비스 DI 패턴 도입** — 프로토콜 기반 서비스 주입
6. **데이터 모델 설계** — Vocabulary, LearningProgress, LevelTag 등
7. **학습 오버레이 UI 설계** — BoxTranslation 확장 (후리가나, 레벨 배지)
8. **FuriganaService 구현** — 한자→후리가나 변환
9. **LevelTaggingService 구현** — JLPT/TOPIK 레벨 데이터베이스

### 7.3 기술 부채 해소

10. **LocalizationService → Localizable.strings 전환**
11. **에러 처리 전략 통일**
12. **ARKit 모드 안정화 또는 분리**
13. **서비스 인스턴스 중복 제거** (ARKitOverlayView)

---

## 8. 결론

YomiLingo는 ViewLingo-Cam에서 성공적으로 마이그레이션된 강력한 실시간 카메라 OCR + 번역 엔진을 보유하고 있다. **OCR 파이프라인, 텍스트 추적 시스템, 적응형 오버레이 렌더링**은 특히 CJK 언어에 대해 잘 최적화되어 있어, 학습 앱의 핵심 기반으로 충분하다.

그러나 **CameraView God Object, 레거시 코드 잔존, 테스트 부재**는 학습 기능 추가 전에 반드시 해결해야 할 기술 부채다. Phase 2(핵심 학습 기능)로 진행하기 전에 CameraView 분리와 서비스 아키텍처 정리를 우선 수행하는 것을 강력히 권장한다.

현재 코드베이스의 전체 규모는 약 **12,000줄** (Swift 30개 파일)로, 기능 대비 적절한 규모이나, 일부 파일(CameraView, AR3DTextManager, TextTracker)의 과도한 크기는 분할이 필요하다.
