# YomiLingo 코드 크리티컬 리뷰

> 리뷰 일시: 2026-02-14
> 리뷰어: Critical Code Reviewer Agent
> 대상: YomiLingo 전체 Swift 소스코드 (~35개 파일, ~12,000+ 라인)

---

## 목차

1. [요약](#요약)
2. [God Objects / Fat Files](#1-god-objects--fat-files)
3. [결합도 (Coupling) 문제](#2-결합도-coupling-문제)
4. [레거시 부채 (Legacy Debt)](#3-레거시-부채-legacy-debt)
5. [추상화 부재 (Missing Abstractions)](#4-추상화-부재-missing-abstractions)
6. [테스트 커버리지](#5-테스트-커버리지)
7. [에러 처리](#6-에러-처리)
8. [동시성 안전성](#7-동시성-안전성)
9. [메모리 관리](#8-메모리-관리)
10. [코드 중복](#9-코드-중복)
11. [네이밍 불일치](#10-네이밍-불일치)
12. [확장성 문제](#11-확장성-문제)
13. [학습앱 준비도](#12-학습앱-준비도)

---

## 요약

YomiLingo는 카메라 OCR + 번역 기능이 작동하는 상태이지만, ViewLingo-Cam에서의 급한 마이그레이션 흔적이 곳곳에 남아있으며 학습 앱으로의 전환은 아직 시작도 되지 않았다. 전체 코드베이스에서 발견된 이슈를 심각도별로 분류하면:

| 심각도 | 개수 | 설명 |
|--------|------|------|
| 🔴 Critical | 12 | 즉시 수정 필요 — 버그, 안전성 문제, 기능 장애 위험 |
| 🟡 Major | 18 | 조기 수정 권장 — 유지보수성, 확장성 저해 |
| 🟢 Minor | 14 | 점진적 개선 — 코드 품질, 일관성 |

**가장 심각한 3가지 문제:**
1. 테스트가 사실상 없음 (placeholder 1개만 존재)
2. 전체 코드베이스가 여전히 "ViewLingo-Cam" 정체성을 유지
3. TranslationCache 싱글톤에 스레드 안전성 없음

---

## 1. God Objects / Fat Files

### 🔴 CR-001: AR3DTextManager.swift — 1,413라인 모놀리식 클래스

**파일:** `YomiLingo/Tracking/AR3DTextManager.swift`
**라인 범위:** 전체 (1-1413)

**문제:** 하나의 클래스가 3D 앵커 생성, 텍스트 유사도 계산, 위치 스무딩, 가시성 관리, 폰트 계산, 디버그 시각화까지 모두 담당한다. SRP(단일 책임 원칙)를 완전히 위반하고 있다.

**수정 방향:**
- `AnchorLifecycleManager` — 앵커 생성/삭제/재사용
- `TextSimilarityEngine` — Levenshtein, 유사도 비교
- `SpatialPositionSmoother` — 위치 스무딩/보간
- `VisibilityController` — 거리 기반 컬링/가시성
- `ARDebugRenderer` — #if DEBUG 전용 시각화

---

### 🔴 CR-002: CameraView.swift — 1,353라인 God View

**파일:** `YomiLingo/Camera/CameraView.swift`
**라인 범위:** 전체 (1-1353)

**문제:** 20개 이상의 `@State` 프로퍼티를 가진 SwiftUI View가 카메라 프리뷰, 언어 선택 UI, 번역 오버레이, 프레임 처리, 캡처 로직, 설정 네비게이션을 모두 포함한다. 또한 `CameraPreviewView`, `LanguageSelectorView`, `LanguageOptionRow`, `LanguageInstallationProvider` 등 4개의 추가 타입이 같은 파일에 정의되어 있다.

**수정 방향:**
- `CameraViewModel: ObservableObject`를 만들어 상태 관리를 분리
- `FrameProcessingPipeline`로 프레임 처리 로직 추출
- `LanguageSelectorView`를 별도 파일로 분리
- 각 하위 뷰를 독립 파일로 이동

---

### 🟡 CR-003: TextTracker.swift — 1,286라인 + 여러 타입 혼합

**파일:** `YomiLingo/Tracking/TextTracker.swift`
**라인 범위:** 전체 (1-1286)

**문제:** `TrackedText` 구조체, `DetectionState` 열거형, `TextTracker` 클래스, `TranslationCache` 싱글톤이 모두 한 파일에 있다. `processNewTexts` 메서드는 약 250라인 이상의 복잡한 로직을 포함한다.

**수정 방향:**
- `TrackedText.swift`, `DetectionState.swift`, `TranslationCache.swift`로 타입 분리
- `processNewTexts`를 단계별 메서드로 분해

---

### 🟡 CR-004: TranslationService.swift — 1,112라인

**파일:** `YomiLingo/Services/TranslationService.swift`
**라인 범위:** 전체 (1-1112)

**문제:** `detectLanguage` 메서드가 약 350라인으로 극단적으로 크다. `commonJapaneseKanji` 세트가 인라인 프로퍼티로 정의되어 있다. 파일 하단에 `TranslationSessionProvider` 뷰가 섞여 있다 (서비스와 뷰의 혼합).

**수정 방향:**
- `LanguageDetector` 클래스로 언어 감지 로직 추출
- `CJKCharacterSets`로 문자 세트 상수 분리
- `TranslationSessionProvider`를 Views/로 이동

---

### 🟡 CR-005: BoxTranslationOverlay.swift — 897라인, 5개 타입

**파일:** `YomiLingo/Views/BoxTranslationOverlay.swift`
**라인 범위:** 전체 (1-897)

**문제:** `BoxTranslationOverlay`, `PlaceholderBox`, `BoxTranslation`, `FontSizeCalculator`, `VerticalJapaneseText` — 5개 타입이 한 파일에 있다. `BoxTranslation`의 `body` 프로퍼티만 약 200라인이다.

**수정 방향:**
- 각 타입을 별도 파일로 분리
- `BoxTranslation.body`를 `@ViewBuilder` 메서드로 분해

---

## 2. 결합도 (Coupling) 문제

### 🟡 CR-006: TranslationCoordinator ↔ TranslationService ↔ OCRService 순환적 의존

**파일:** `TranslationCoordinator.swift`, `TranslationService.swift`, `OCRService.swift`

**문제:** 세 서비스 모두 독립적으로 언어 감지(`detectLanguage`)를 구현하고 있다. `TranslationCoordinator`는 자체 캐시를 유지하면서 동시에 `TranslationCache.shared`도 접근한다. `TranslationService` 내부에 `TranslationSessionProvider` 뷰가 있어서 서비스가 UI에 의존한다.

**수정 방향:**
- 언어 감지를 단일 `LanguageDetector` 서비스로 통합
- 캐시를 `TranslationCache`로 단일화
- 뷰 컴포넌트를 서비스 파일에서 제거

---

### 🟡 CR-007: AppState가 모든 곳에서 직접 참조됨

**파일:** `AppState.swift` + 거의 모든 View 파일

**문제:** `@EnvironmentObject var appState: AppState`가 거의 모든 뷰에서 사용된다. AppState 변경이 전체 뷰 트리를 리렌더링할 수 있다. 특히 `SettingsView`에서 `TranslationService()`를 인라인으로 생성하여 `missingLanguagePacks`를 확인하는 패턴(라인 387)은 불필요한 인스턴스 생성이다.

**파일:** `YomiLingo/Views/SettingsView.swift:387`

```swift
let hasRecentErrors = TranslationService().missingLanguagePacks.count > 0
```

이 코드는 상태 확인을 위해 새로운 TranslationService 인스턴스를 매번 생성한다.

**수정 방향:**
- AppState를 도메인별로 분리 (CameraState, TranslationState, SettingsState)
- 서비스 인스턴스를 생성하지 말고 공유 인스턴스를 주입

---

## 3. 레거시 부채 (Legacy Debt)

### 🔴 CR-008: 전체 코드베이스 — "ViewLingo-Cam" 잔재

**파일:** 모든 .swift 파일
**영향 범위:** 35개+ 파일

**상세 목록:**

| 카테고리 | 위치 | 내용 |
|----------|------|------|
| 파일 헤더 | 모든 .swift 파일 | `// ViewLingo-Cam` |
| 앱 진입점 | `ViewLingoCamApp.swift:11` | `struct ViewLingoCamApp: App` |
| 앱 이름 | `ViewLingoCamApp.swift:15` | `"ViewLingo-Cam Starting..."` |
| UserDefaults | `AppState.swift` 전체 | `"VLC."` 접두사 키 (VLC.targetLanguage 등) |
| DispatchQueue | `CameraManager.swift:27-28` | `"com.viewlingo.camera"`, `"com.viewlingo.frameProcessing"` |
| DispatchQueue | `ARKitTracker.swift:24` | `"com.viewlingo.arkit"` |
| DispatchQueue | `VisionTracker.swift:43` | `"com.viewlingo.visiontracker"` |
| OperationQueue | `MotionTracker.swift:48` | `"com.viewlingo.motion"` |
| 로그 시스템 | `Logger.swift:31` | `OSLog(subsystem: "com.viewlingo.cam")` |
| 로그 파일 | `Logger.swift:50` | `"ViewLingoCam.log"` |
| CIContext | `CIContextHelper.swift:24` | `"ViewLingo-CIContext"` |
| 파일명 | `CapturedImageView.swift:611` | `"ViewLingo_\(Date()...)"` |
| UnsupportedView | `ViewLingoCamApp.swift:46` | `"ViewLingo Cam requires iOS 18..."` |

**수정 방향:**
- 전체 일괄 치환: `ViewLingo-Cam` → `YomiLingo`, `VLC.` → `YL.`, `com.viewlingo` → `com.yomilingo`
- `ViewLingoCamApp.swift` → `YomiLingoApp.swift`로 파일명 변경
- `struct ViewLingoCamApp` → `struct YomiLingoApp`

---

### 🟡 CR-009: 주석 처리된 코드 다수

**파일:** 여러 파일

| 파일 | 라인 | 내용 |
|------|------|------|
| `SettingsView.swift` | 207-238 | AR 모드 설정 전체 블록이 주석 처리됨 (#else 내부) |
| `OCRService.swift` | 다수 | 비활성화된 엣지 필터링 코드 |
| `VisionTracker.swift` | 283-296 | `performRealOpticalFlow` 내부 전체가 주석 |
| `ARKitTracker.swift` | 78 | `// arSession?.delegate = self  // REMOVED` |

**수정 방향:**
- 주석 처리된 코드를 삭제하고 git 히스토리에 의존
- 필요시 TODO 주석으로 대체

---

## 4. 추상화 부재 (Missing Abstractions)

### 🔴 CR-010: 프로토콜/인터페이스 전무

**파일:** 전체 코드베이스

**문제:** 프로젝트에 프로토콜이 단 하나도 정의되어 있지 않다. 모든 서비스(`OCRService`, `TranslationService`, `TranslationCoordinator`)가 구체적 클래스로만 존재한다. 이로 인해:
- 단위 테스트에서 mock 주입 불가능
- 서비스 교체 불가능 (예: 테스트용 더미 OCR)
- 의존성 역전 원칙 위반

**필요한 프로토콜 목록:**
```swift
protocol OCRServiceProtocol {
    func processImage(_ image: CIImage) async
    var recognizedTexts: [RecognizedText] { get }
}

protocol TranslationServiceProtocol {
    func translate(texts: [String], from: String, to: String) async -> [String: String]
}

protocol TextTrackerProtocol {
    func processNewTexts(_ texts: [RecognizedText])
    var trackedTexts: [TrackedText] { get }
}

protocol LanguageDetectorProtocol {
    func detectLanguage(for text: String) -> String?
    func detectLanguages(for texts: [String]) -> [String: [String]]
}
```

---

### 🟡 CR-011: 에러 타입 미정의

**파일:** 전체 코드베이스

**문제:** 프로젝트 전용 Error 타입이 없다. 모든 에러가 `Error` 프로토콜이나 `String`으로 처리된다. `Logger.shared.log(.error, ...)` 호출만으로 에러를 "처리"하는 패턴이 반복된다.

**수정 방향:**
```swift
enum YomiLingoError: Error, LocalizedError {
    case ocrFailed(underlying: Error)
    case translationSessionUnavailable(source: String, target: String)
    case languagePackNotInstalled(language: String)
    case cameraAccessDenied
    case arSessionFailed(reason: String)
    // ...
}
```

---

## 5. 테스트 커버리지

### 🔴 CR-012: 테스트가 사실상 존재하지 않음

**파일:** `YomiLingoTests/YomiLingoTests.swift`
**라인:** 1-17

**전체 테스트 코드:**
```swift
import Testing

struct YomiLingoTests {
    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }
}
```

**심각성:** 12,000라인 이상의 프로덕션 코드에 대해 테스트가 0개다. 빈 placeholder만 존재한다. 이는:
- 리팩토링 시 회귀 감지 불가능
- 번역 파이프라인 정확성 검증 불가
- OCR 결과 품질 보장 불가
- TextTracker 동작 검증 불가

**수정 방향 (우선순위):**
1. `TranslationCoordinatorTests` — 번역 파이프라인 단위 테스트
2. `TextTrackerTests` — 텍스트 추적, 유사도 매칭, 프로모션 로직
3. `TextRecoveryTests` — OCR 보정 정확성
4. `LanguageDetectionTests` — 언어 감지 정확성
5. `TranslationCacheTests` — 캐시 동작
6. `SceneChangeDetectorTests` — 장면 변화 감지

---

## 6. 에러 처리

### 🟡 CR-013: "로그만 남기고 무시" 패턴

**파일:** 전체 코드베이스

**문제:** 대부분의 에러 처리가 `Logger.shared.log(.error, ...)` 후 `return`하는 패턴이다. 사용자에게 에러가 전달되지 않는다.

**대표적 사례:**

| 파일 | 라인 | 상황 |
|------|------|------|
| `CameraManager.swift:170-174` | 비디오 입력 생성 실패 | `self.error = error`만 설정하고 UI에서 확인 안 함 |
| `OCRService.swift` | 전체 | processImage 실패 시 빈 결과만 반환 |
| `ARFrameProcessor.swift:142-146` | ARKit 세션 실패 | 로그만 남김 |
| `DynamicLanguagePackProvider.swift:80-92` | 언어팩 설치 실패 | 로그 후 nil 콜백 |

**수정 방향:**
- 사용자 영향 에러는 `AppState`에 에러 상태를 전파
- 알림/토스트로 사용자에게 적절히 표시
- 복구 가능한 에러는 재시도 메커니즘 추가

---

### 🟡 CR-014: TranslationService.getCacheHitRate() 잘못된 계산

**파일:** `YomiLingo/Services/TranslationService.swift`

**문제:** `getCacheHitRate()`가 실제 히트율이 아니라 캐시 크기 비율을 반환한다. 실제 cache hit/miss 카운팅이 없으므로 이 메트릭은 의미가 없다.

**수정 방향:**
- 실제 cache hit/miss 카운터를 추가
- `hitCount / (hitCount + missCount)`로 정확한 히트율 계산

---

## 7. 동시성 안전성

### 🔴 CR-015: TranslationCache 싱글톤 — 스레드 안전성 없음

**파일:** `YomiLingo/Tracking/TextTracker.swift` (TranslationCache 정의 위치)

**문제:** `TranslationCache`는 `class TranslationCache`로 선언되어 있으며 `@MainActor`도 아니고 lock도 없다. `shared` 싱글톤이 여러 스레드에서 동시 접근될 수 있다. 특히:
- `CameraView`에서 프레임 처리 중 캐시 읽기
- `ARKitOverlayView.Coordinator`에서 캐시 읽기/쓰기
- `TranslationCoordinator`에서 캐시 쓰기

`get(for:)`과 `set(for:translation:)`이 동시에 호출되면 딕셔너리 concurrent modification으로 크래시 가능.

**수정 방향:**
```swift
@MainActor  // 또는 내부 lock 추가
class TranslationCache {
    // ...
}
```

---

### 🟡 CR-016: CameraManager의 nonisolated 메서드에서 @MainActor 호출

**파일:** `YomiLingo/Camera/CameraManager.swift:372-403`

**문제:** `captureOutput(_:didOutput:from:)`은 `nonisolated`로 선언되어 `frameProcessingQueue`에서 호출된다. 이 메서드 내부에서 `Task { @MainActor in ... }`으로 메인 스레드로 전환한다. 프레임이 15fps로 들어오므로 초당 15개의 Task가 생성된다. 이는 과도한 task 생성이며, 프레임 드롭 시에도 `droppedFrameCount` 업데이트를 위해 별도 Task를 생성한다.

**수정 방향:**
- `@Published var frameUpdateCount`를 Combine Subject로 변경하여 배압 처리
- 프레임 드롭 카운터는 atomic 변수로 관리

---

### 🟡 CR-017: ARKitOverlayView.Coordinator에서 DispatchGroup + async/await 혼용

**파일:** `YomiLingo/Views/ARKitOverlayView.swift:415-438`

**문제:** `translateTrackedTexts` 메서드가 `DispatchGroup`과 `withCheckedContinuation`을 혼합하여 사용한다. 현대 Swift 동시성 패턴으로 통일해야 한다.

```swift
let group = DispatchGroup()
// ...
group.enter()
// ...
group.leave()
// ...
await withCheckedContinuation { continuation in
    group.notify(queue: .main) {
        continuation.resume()
    }
}
```

**수정 방향:** `withTaskGroup`으로 통일 (CapturedImageView에서는 이미 이 패턴을 사용하고 있음)

---

### 🟡 CR-018: ARFrameProcessor.isProcessing — 스레드 안전하지 않은 플래그

**파일:** `YomiLingo/Tracking/ARFrameProcessor.swift:24,89-91`

**문제:** `isProcessing` Bool 플래그가 `processingQueue`와 메인 스레드 양쪽에서 읽기/쓰기된다. `ARSessionDelegate` 콜백은 ARKit 내부 스레드에서 호출되고, `isProcessing` 체크/설정은 lock 없이 수행된다.

```swift
// ARSession 스레드에서 호출
guard !isProcessing else { return }  // 읽기

// processingQueue에서 실행
guard !isProcessing else { return }  // 읽기
isProcessing = true                   // 쓰기

// MainActor에서 실행
self.isProcessing = false            // 쓰기
```

**수정 방향:** `AtomicInt` 패턴처럼 atomic boolean을 사용하거나 actor로 전환

---

## 8. 메모리 관리

### 🟡 CR-019: CapturedImageView에서 매번 OCRService 인스턴스 생성

**파일:** `YomiLingo/Views/CapturedImageView.swift:19`

```swift
@StateObject private var ocrService = OCRService()
```

**문제:** 캡처할 때마다 새 `OCRService` 인스턴스가 생성된다. `OCRService`는 내부에 `processingQueue`, 정규식 컴파일, 다양한 상태를 가진 무거운 객체이다. `TextTracker`도 `performHighQualityOCR()` 내부에서 매번 새로 생성된다(라인 284).

**수정 방향:**
- 부모 뷰에서 공유 OCRService를 전달받아 사용
- 또는 싱글톤/환경 객체로 관리

---

### 🟡 CR-020: Logger의 파일 쓰기 — FileHandle 매번 열고 닫기

**파일:** `YomiLingo/Utils/Logger.swift:132-144`

```swift
private func writeToFile(_ message: String) {
    guard let fileURL = fileURL else { return }
    if let data = messageWithNewline.data(using: .utf8) {
        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        }
    }
}
```

**문제:** 로그 메시지마다 FileHandle을 열고/닫는다. 디버그 모드에서 초당 수십 개의 로그가 생성되므로 파일 I/O 오버헤드가 크다.

**수정 방향:**
- FileHandle을 한 번 열고 유지
- 배치 쓰기 (버퍼링 후 일정 간격으로 flush)
- 또는 OS 통합 로깅(`os_log`)만 사용

---

### 🟢 CR-021: 미사용 변수 할당

**파일 및 위치:**

| 파일 | 라인 | 코드 |
|------|------|------|
| `AR3DTextManager.swift` | ~224 | `let _ = sqrt(dx * dx + dy * dy)` |
| `AR3DTextManager.swift` | ~1034-1035 | `_ = Float(screenPoint.x / ...)` |
| `AR3DTextManager.swift` | ~1055 | `_ = screenWidth / screenHeight` |
| `CapturedImageView.swift` | 556 | `let _ = image.size.width / UIScreen.main.bounds.width` |
| `ARTranslationOverlay.swift` | 79 | `let _ : CGFloat = 60` (주석으로 "unused but kept for reference") |

**수정 방향:** 미사용 계산을 완전히 제거

---

## 9. 코드 중복

### 🔴 CR-022: Levenshtein Distance — 최소 3곳에서 독립 구현

**파일:**
1. `AR3DTextManager.swift` — `levenshteinDistance` 메서드
2. `TextTracker.swift` — `levenshteinDistance` 메서드
3. `TextRecovery.swift` — `levenshteinDistance` 메서드

**문제:** 동일한 알고리즘이 3개 파일에서 완전히 독립적으로 구현되어 있다. 하나를 수정하면 나머지 2개도 수정해야 하며, 동작 불일치 위험이 있다.

**수정 방향:**
```swift
// Utils/StringDistance.swift
enum StringDistance {
    static func levenshtein(_ s1: String, _ s2: String) -> Int { ... }
    static func similarity(_ s1: String, _ s2: String) -> Double { ... }
}
```

---

### 🔴 CR-023: 언어 감지 — 3개 독립 구현

**파일:**
1. `TranslationService.swift` — 약 350라인의 복잡한 `detectLanguage` (NLLanguageRecognizer + 규칙 기반)
2. `TranslationCoordinator.swift` — 약 60라인의 `detectLanguages` (NLLanguageRecognizer + 간단한 규칙)
3. `OCRService.swift` — 약 40라인의 `detectLanguage` (NLLanguageRecognizer + CJK 문자 비율)

**문제:** 3가지 구현이 서로 다른 결과를 줄 수 있다. 예를 들어 같은 텍스트에 대해 OCRService는 "ja"로, TranslationService는 "ko"로, TranslationCoordinator는 "zh"로 감지할 수 있다.

**수정 방향:**
- 단일 `LanguageDetector` 서비스로 통합
- 가장 정확한 TranslationService 버전을 기반으로 통합
- 프로토콜을 정의하여 테스트 가능하게 설계

---

### 🟡 CR-024: CJK 정규식 패턴 — 10곳 이상 중복

**파일:** `BoxTranslationOverlay.swift`, `TextTracker.swift`, `OCRService.swift`, `TranslationService.swift`, `TextRecovery.swift`, `AR3DTextManager.swift`

**문제:** `[\u{4E00}-\u{9FFF}]`, `[\u{3040}-\u{309F}]`, `[\u{AC00}-\u{D7AF}]` 등의 CJK 문자 범위 정규식이 10곳 이상에서 반복된다. 각 위치마다 범위가 약간씩 다르기도 하다 (예: `\u{9FFF}` vs `\u{9FAF}`).

**수정 방향:**
```swift
enum CJKPatterns {
    static let kanji = "\\u{4E00}-\\u{9FFF}"
    static let hiragana = "\\u{3040}-\\u{309F}"
    static let katakana = "\\u{30A0}-\\u{30FF}"
    static let hangul = "\\u{AC00}-\\u{D7AF}"
    static let cjkAll = "[\(kanji)\(hiragana)\(katakana)\(hangul)]"
}
```

---

### 🟡 CR-025: 좌표 변환 — 여러 뷰에서 중복

**파일:** `BoxTranslationOverlay.swift`, `ARTranslationOverlay.swift`, `CapturedImageView.swift`

**문제:** "정규화 좌표 → 화면 좌표" 변환 로직이 각 뷰에서 독립적으로 구현되어 있다:
- `PlaceholderBox.screenBox` (BoxTranslationOverlay.swift:102-119)
- `BoxTranslation.screenBox` (BoxTranslationOverlay.swift:227-245)
- `TranslationBubble.position` (ARTranslationOverlay.swift:72-89)
- `CapturedImageView.calculateImageRect` (CapturedImageView.swift:527-546)

`PlaceholderBox`와 `BoxTranslation`의 `screenBox` 계산은 거의 동일한 코드이다.

**수정 방향:**
- `CoordinateConverter` 유틸리티로 통합
- Y축 뒤집기, 캡처 이미지 오프셋 등을 파라미터화

---

### 🟡 CR-026: isJapaneseText / isKoreanText / isEnglishOrLatinText 헬퍼 중복

**파일:** `BoxTranslationOverlay.swift:618-643` (BoxTranslation 내부)

**문제:** 이 헬퍼들은 BoxTranslation 내부 private 메서드로만 존재하지만, 유사한 로직이 TextTracker, OCRService, TranslationService에서도 반복된다.

**수정 방향:** 공통 `TextCharacterAnalyzer` 또는 String extension으로 통합

---

### 🟡 CR-027: ARWorldTrackingConfiguration 설정 — 3곳 중복

**파일:**
1. `ARKitOverlayView.swift:89-115` (makeUIView)
2. `ARKitOverlayView.swift:194-214` (updateUIView)
3. `ARKitTracker.swift:59-79` (setupARSession)

**문제:** ARWorldTrackingConfiguration 초기 설정이 3곳에서 거의 동일하게 반복된다. iPad/iPhone 분기 로직도 중복이다.

**수정 방향:**
```swift
extension ARWorldTrackingConfiguration {
    static func optimizedForTextOverlay() -> ARWorldTrackingConfiguration { ... }
}
```

---

## 10. 네이밍 불일치

### 🟡 CR-028: 파일명 vs 타입명 vs 앱명 불일치

| 항목 | 현재 값 | 기대 값 |
|------|---------|---------|
| Xcode 프로젝트 | `YomiLingo.xcodeproj` | ✅ |
| 앱 진입점 파일 | `ViewLingoCamApp.swift` | `YomiLingoApp.swift` |
| 앱 구조체 | `struct ViewLingoCamApp` | `struct YomiLingoApp` |
| 로그 메시지 | "ViewLingo-Cam Starting" | "YomiLingo Starting" |
| OSLog subsystem | "com.viewlingo.cam" | "com.yomilingo" |

---

### 🟢 CR-029: 주석 언어 혼합

**파일:** 전체 코드베이스

**문제:** 코드 주석이 영어와 한국어가 섞여 있다:
- `SettingsView.swift:110` — `"번역 소스 언어"` (한국어 Section 헤더)
- `SettingsView.swift:111` — `"화면에서 인식할 언어 선택 (최소 1개)"` (한국어 설명)
- `SettingsView.swift:134` — `"(대상 언어)"` (한국어 라벨)
- `LanguagePackService.swift:29` — 주석은 영어
- `DebugView.swift` — 거의 전부 한국어 문자열

LocalizationService에 등록되지 않은 하드코딩된 한국어 문자열이 다수 존재.

**수정 방향:**
- 모든 UI 문자열을 `LocalizationService.L()`로 통일
- 코드 주석은 영어로 통일 (또는 한국어로 통일 — 하나만 선택)

---

### 🟢 CR-030: LocalizationService에 "fr" (프랑스어) 누락

**파일:** `YomiLingo/Services/LocalizationService.swift`

**문제:** `getSystemLanguage()`는 ko, ja, en만 지원한다. 그런데 `LanguagePackService`와 `BatchLanguagePackProvider`에서 "fr" (프랑스어)를 지원 언어로 포함하고 있다. LocalizationService에는 프랑스어 문자열 사전(`frenchStrings`)이 없다.

**수정 방향:**
- 프랑스어를 공식 지원하려면 LocalizationService에 프랑스어 문자열 추가
- 아니면 BatchLanguagePackProvider에서 프랑스어 관련 코드 제거

---

## 11. 확장성 문제

### 🟡 CR-031: LocalizationService — 정적 딕셔너리 방식의 한계

**파일:** `YomiLingo/Services/LocalizationService.swift`

**문제:** 모든 번역 문자열이 `private static let koreanStrings: [String: String]` 같은 하드코딩된 딕셔너리에 저장되어 있다. 새 문자열 추가 시 3개 딕셔너리(ko, en, ja)를 모두 수정해야 하며, 컴파일 타임 키 검증이 없다. 오타가 있어도 런타임에서만 발견된다.

**수정 방향:**
- Apple의 `String(localized:)` 및 `.strings`/`.xcstrings` 파일 사용
- 또는 enum 기반 키 시스템:
```swift
enum LocalizationKey: String {
    case done, cancel, reset
    // ...
}
```

---

### 🟡 CR-032: LanguagePackService.checkAllStatuses() — 중복 체크

**파일:** `YomiLingo/Services/LanguagePackService.swift:92-117`

**문제:** `checkAllStatuses()`에서 같은 페어를 여러 번 중복 체크한다:
```swift
await checkPairStatus(from: "en", to: "ko")  // 라인 98
// ...
await checkPairStatus(from: "en", to: "ko")  // 라인 106 (중복!)
await checkPairStatus(from: "ko", to: "en")  // 라인 100
await checkPairStatus(from: "ko", to: "en")  // 라인 104 (중복!)
```

6개 고유 페어만 필요한데 12번 체크하고 있다.

**수정 방향:**
```swift
let uniquePairs = Set(supportedLanguages.flatMap { source in
    supportedLanguages.compactMap { target in
        source != target ? LanguagePair(source: source, target: target) : nil
    }
})
for pair in uniquePairs {
    await checkPairStatus(from: pair.source, to: pair.target)
}
```

---

### 🟢 CR-033: DebugView — 하드코딩된 성능 수치

**파일:** `YomiLingo/Views/DebugView.swift:175-193`

**문제:** 성능 뷰의 수치가 전부 하드코딩되어 있다:
```swift
InfoRow(label: "캐시", value: "200 항목")
InfoRow(label: "OCR 평균", value: "250ms")
InfoRow(label: "번역 평균", value: "150ms")
InfoRow(label: "프레임 처리", value: "15 FPS")
```

이 값들은 실제 성능을 반영하지 않는 가짜 데이터이다.

**수정 방향:** 실제 메트릭 수집 시스템 구현 또는 해당 섹션 제거

---

### 🟢 CR-034: ARTranslationOverlay.fontSize — 조건 순서 오류

**파일:** `YomiLingo/Views/ARTranslationOverlay.swift:138-147`

```swift
private var fontSize: CGFloat {
    let baseSize: CGFloat = 14
    if translatedText.count > 50 {
        return baseSize * 0.85
    } else if translatedText.count > 100 {  // ← 절대 도달하지 않음!
        return baseSize * 0.7
    }
    return baseSize
}
```

**문제:** `count > 100`은 `count > 50` 이후에 위치하여 절대 실행되지 않는 데드 코드이다.

**수정 방향:** 조건 순서를 `> 100` → `> 50`으로 변경

---

## 12. 학습앱 준비도

### 🔴 CR-035: 학습 앱 기능이 전혀 구현되지 않음

**파일:** 전체 코드베이스

**문제:** `DEVELOPMENT_PLAN.md`에 명시된 학습 앱 핵심 기능이 하나도 구현되지 않았다:

| 계획된 기능 | 현재 상태 | 필요한 작업 |
|-------------|-----------|-------------|
| FuriganaService | ❌ 미존재 | 일본어 한자 위 후리가나 표시 |
| PronunciationService | ❌ 미존재 | 발음 가이드 (한국어↔일본어) |
| VocabularyManager | ❌ 미존재 | 단어장 저장/관리 |
| LevelTaggingService (JLPT/TOPIK) | ❌ 미존재 | 난이도 태깅 |
| SpacedRepetitionEngine | ❌ 미존재 | 간격 반복 학습 |
| ProgressTracker | ❌ 미존재 | 학습 진행 추적 |

현재 앱은 "카메라 번역기"이지 "언어 학습 앱"이 아니다.

**수정 방향:**
- 학습 앱 피벗의 Phase 1으로 먼저 데이터 모델 설계 필요:
  - `Word` / `Vocabulary` 모델
  - `LearningProgress` 모델
  - `CoreData` 또는 `SwiftData` 기반 영구 저장소
- 이후 번역 결과에 학습 메타데이터(난이도, 품사, 예문)를 추가

---

### 🟡 CR-036: AppState에 학습 관련 상태 없음

**파일:** `YomiLingo/App/AppState.swift`

**문제:** 현재 AppState는 카메라/번역 설정만 관리한다. 학습 앱에 필요한 상태가 전혀 없다:
- 현재 학습 세션 정보
- 사용자 레벨/진행도
- 학습 모드 (자유 탐색 / 집중 학습 / 복습)
- 즐겨찾기/단어장 상태
- 일일 학습 목표

**수정 방향:** `LearningState` ObservableObject를 별도로 설계

---

### 🟢 CR-037: 한국어↔일본어 특화 기능 부재

**파일:** 전체 코드베이스

**문제:** `CLAUDE.md`에 "일본어 for 한국어 화자, 한국어 for 일본어 화자"로 명시되어 있지만, 현재 코드에는 이 두 언어 조합에 대한 특별한 처리가 없다. 영어도 동등하게 지원되며, 한일 학습에 특화된 기능(한자 읽기, 유사 표현 비교, 조사 대응 등)이 전무하다.

---

## 추가 발견 사항

### 🟢 CR-038: TextRecovery — 상충하는 보정 규칙

**파일:** `YomiLingo/Services/TextRecovery.swift`

**문제:** `applyJapaneseCorrections`에서 `ソ→ン`과 `ン→ソ` 양방향 보정이 모두 존재한다. 입력에 따라 한쪽이 잘못 적용될 수 있다. `koreanJapaneseMisrecognitions`도 양방향이지만 문자 수 기반으로만 방향을 결정하는데, 이는 신뢰할 수 없는 휴리스틱이다.

---

### 🟢 CR-039: CIContextHelper — "ViewLingo-CIContext" 이름

**파일:** `YomiLingo/Utils/CIContextHelper.swift:24`

**문제:** 레거시 이름 잔재 (CR-008과 동일 카테고리)

---

### 🟢 CR-040: UnsafeSendable — CVPixelBuffer의 Sendable 안전성 가정

**파일:** `YomiLingo/Utils/UnsafeSendable.swift`

**문제:** `CVPixelBuffer`를 `@unchecked Sendable`로 래핑하고 있다. 주석에서 "CVPixelBuffer is thread-safe internally"라고 주장하지만, CVPixelBuffer의 lock/unlock 없이 다른 스레드에서 동시 접근하면 데이터 경쟁이 발생할 수 있다. `ARFrameProcessor.copyPixelBuffer`에서 올바르게 복사 후 전달하는 패턴을 쓰고 있지만, 복사 없이 직접 전달하는 곳도 있다 (`VisionTracker.updateTracking`).

**수정 방향:** CVPixelBuffer를 전달하기 전에 항상 lock/unlock하거나 복사본 사용을 강제

---

### 🟢 CR-041: LanguagePackService.checkAllStatuses — 순차 실행

**파일:** `YomiLingo/Services/LanguagePackService.swift:92-117`

**문제:** CR-032에서 지적한 중복 외에, 모든 `checkPairStatus` 호출이 순차적으로 실행된다 (`await` 사용). 6개 이상의 네트워크/시스템 호출을 하나씩 기다리므로 느리다.

**수정 방향:** `withTaskGroup`으로 병렬 실행

---

## 우선순위별 액션 플랜

### 즉시 수정 (Sprint 1)
1. **CR-015** — TranslationCache 스레드 안전성 확보 (`@MainActor` 추가)
2. **CR-008** — ViewLingo-Cam 레거시 이름 일괄 치환
3. **CR-022/023** — Levenshtein + 언어 감지 중복 제거 (공통 유틸리티로 통합)
4. **CR-034** — fontSize 조건 순서 버그 수정

### 단기 수정 (Sprint 2-3)
5. **CR-012** — 핵심 서비스 단위 테스트 추가 (최소 TextTracker, TranslationCoordinator, TextRecovery)
6. **CR-010** — 핵심 프로토콜 정의 (OCRServiceProtocol, TranslationServiceProtocol)
7. **CR-001/002** — God Object 분해 시작 (AR3DTextManager, CameraView)
8. **CR-024/025** — CJK 패턴 + 좌표 변환 중복 제거

### 중기 개선 (Phase 2)
9. **CR-035** — 학습 앱 데이터 모델 설계 및 기본 구현
10. **CR-006/007** — 서비스 간 결합도 감소
11. **CR-031** — 로컬라이제이션 시스템 현대화
12. **CR-011** — 커스텀 에러 타입 도입

---

*이 리뷰는 코드베이스의 현재 상태를 정직하게 분석한 것이며, 프로젝트의 개선을 위한 건설적인 피드백을 목적으로 한다. 핵심 번역/OCR 기능은 작동하고 있으며, 위 문제들을 체계적으로 해결하면 학습 앱으로의 전환을 위한 튼튼한 기반을 마련할 수 있다.*
