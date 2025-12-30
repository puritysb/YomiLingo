# YomiLingo 개발 계획

## 컨셉
- **하나의 앱, 두 가지 모드**
- 일본어 학습 모드 (한국인용)
- 한국어 학습 모드 (일본인용)
- 카메라로 실시간 텍스트 인식 → 학습 오버레이 표시

## 타겟 시장
- 한국: 일본어 배우는 한국인 (애니, 게임, 여행)
- 일본: 한국어 배우는 일본인 (K-pop, 드라마, 여행)

---

## 기존 코드 활용 계획

### 그대로 재사용 (Core)
| 파일 | 기능 | 학습 앱 활용 |
|-----|------|------------|
| `OCRService.swift` | 텍스트 인식 | 단어 추출 엔진 |
| `TextTracker.swift` | 텍스트 추적 | 학습 진도 추적 |
| `TranslationService.swift` | 번역 | 뜻/예문 조회 |
| `TextRecovery.swift` | OCR 보정 | 한글/일본어 오류 수정 |
| `CameraManager.swift` | 카메라 | 실시간 캡처 |
| `LanguagePackService.swift` | 언어팩 | 오프라인 지원 |

### 수정 필요 (UI/UX)
| 파일 | 현재 | 변경 |
|-----|------|------|
| `ARTranslationOverlay.swift` | 번역 버블 | 학습 카드 (뜻+발음+레벨) |
| `SettingsView.swift` | 번역 설정 | 학습 모드/레벨 선택 |
| `AppState.swift` | 번역 상태 | 학습 진도/단어장 |
| `CameraView.swift` | 번역 UI | 학습 UI |

### 새로 개발 필요
- [ ] **FuriganaService** - 후리가나 생성
- [ ] **PronunciationService** - 한글 발음 표시
- [ ] **VocabularyManager** - 단어장 저장/관리
- [ ] **LevelTaggingService** - JLPT/TOPIK 레벨 태깅
- [ ] **SpacedRepetitionEngine** - 복습 알고리즘
- [ ] **LearningModeSelector** - 모드 전환 UI
- [ ] **ProgressTracker** - 학습 통계

---

## 핵심 기능 정의

### 공통 기능
1. 카메라로 텍스트 인식
2. 단어 터치 → 뜻/발음/예문 표시
3. 단어장에 저장
4. 난이도 레벨 표시
5. 복습 알림

### 일본어 학습 모드 (한국인용)
- 한자에 **후리가나** 표시
- **JLPT 레벨** (N5~N1) 태깅
- 한국어 뜻 표시

### 한국어 학습 모드 (일본인용)
- 한글에 **일본어 발음** 표시
- **TOPIK 레벨** (1~6급) 태깅
- 일본어 뜻 표시

---

## 개발 단계

### Phase 1: 기반 구축
1. 기존 코드를 학습 앱 구조로 재편
2. 학습 모드 선택 UI 추가
3. 단어장 데이터 모델 설계

### Phase 2: 핵심 학습 기능
4. 후리가나/발음 표시 구현
5. JLPT/TOPIK 레벨 태깅
6. 단어장 저장/관리

### Phase 3: 고급 기능
7. 복습 알고리즘 (Spaced Repetition)
8. 학습 통계/진도
9. 오프라인 모드 최적화

---

## 기술 스택
- **iOS 18.0+** (TranslationSession API)
- **Swift 6.0**
- **Vision Framework** - OCR
- **Translation Framework** - 온디바이스 번역
- **AVFoundation** - 카메라
- **SwiftUI/UIKit**

## Bundle ID
`bound.serendipity.YomiLingo`

---

## 메모
- 2024-12-31: 프로젝트 생성, ViewLingo-Cam 코드 마이그레이션 완료
- GitHub: https://github.com/puritysb/YomiLingo
