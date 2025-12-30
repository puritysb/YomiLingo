//
//  LocalizationService.swift
//  ViewLingo-Cam
//
//  Localization service that changes UI language based on target translation language
//

import Foundation

class LocalizationService {
    
    // MARK: - Korean Strings
    private static let koreanStrings: [String: String] = [
        // Common
        "done": "완료",
        "cancel": "취소",
        "reset": "초기화",
        "close": "닫기",
        "version": "버전",
        "confirm": "확인",
        
        // Camera View
        "camera_preparing": "카메라 준비 중...",
        "camera_permission_denied": "카메라 접근 권한이 필요합니다",
        "camera_permission_denied_desc": "실시간 번역을 위해 카메라 접근이 필요합니다. 설정에서 카메라 권한을 허용해주세요.",
        "translation_target": "번역 대상 언어",
        "language_pack_auto_install": "카메라 사용 중 해당 언어가 감지되면 필요한 번역 팩이 자동으로 설치됩니다",
        "language_pack_install_on_demand": "번역 시도 시 필요한 경우 번역 팩 설치 팝업이 표시됩니다",
        "language_pack_installing": "언어팩 설치 중...",
        "live_mode_paused_title": "Live 모드 일시 중지",
        "live_mode_paused_message": "Live 모드가 배터리 절약을 위해 일시 중지되었습니다. 필요시 다시 활성화해주세요.",
        
        // Settings
        "settings": "설정",
        "language_settings": "언어 설정",
        "target_language": "번역 대상 언어",
        "translation_mode": "번역 모드",
        "on_device_mode": "온디바이스 모드",
        "enabled": "활성화됨",
        "disabled": "비활성화됨",
        "needs_on_device_mode": "온디바이스 모드 필요",
        "on_device_mode_required": "온디바이스 모드 필요",
        "on_device_mode_instruction_1": "1. iOS 설정 > 번역 열기",
        "on_device_mode_instruction_2": "2. '온디바이스 모드' 켜기",
        "on_device_mode_instruction_3": "3. 필요한 언어 다운로드",
        "on_device_mode_alert_message": "번역이 작동하지 않나요?\n\niOS 설정 > 번역에서:\n1. '온디바이스 모드' 활성화\n2. 필요한 언어 다운로드\n\n이렇게 하면 오프라인에서도 번역이 가능합니다.",
        "open_settings": "설정 열기",
        "on_device_translation_instruction": "온디바이스 번역을 사용하려면:",
        "open_translation_settings": "번역 설정 열기",
        "information": "정보",
        "ios_minimum_version": "iOS 최소 버전",
        "ar_mode": "AR 모드",
        "ar_tracking_method": "AR 추적 방식",
        "reset_app_settings": "앱 설정 초기화",
        "reset_app_settings_message": "앱 설정을 기본값으로 되돌립니다. 언어 팩은 iOS 설정에서 직접 관리해야 합니다.",
        "language_pack_management": "언어 팩 관리",
        "language_pack_manage_instruction": "언어 팩을 관리하려면:",
        "language_pack_manage_path": "설정 → 앱 → 번역 → 다운로드된 언어",
        "language_pack_manage_description": "목록에서 언어 팩을 삭제할 수 있습니다.",
        
        // Progress Messages (Simplified)
        "processing": "처리 중...",
        "processing_complete": "처리 완료",
        "ocr_processing": "텍스트 인식 중...",
        "translating": "번역 중...",
        
        // AR Modes
        "ar_standard": "표준 2D 추적 (권장)",
        "ar_arkit": "ARKit 3D 추적 (실험적)",
        "arkit_live_only": "ARKit 모드: 실시간 번역만 지원",
        "arkit_experimental_note": "실험적 기능 - 정확도가 낮을 수 있음",
        
        // Debug
        "debug_info": "디버그 정보",
        "clear_logs": "로그 지우기",
        "language_packs": "언어 팩",
        "app_state": "앱 상태",
        "logs": "로그",
        "performance": "성능",
        "language_pack_status": "언어 팩 상태",
        "checking_status": "상태 확인 중...",
        "translation_pack_installed": "번역 팩 설치됨",
        "available_in_camera": "카메라에서 설치 가능",
        "installing": "설치 중...",
        "not_supported": "지원되지 않음"
    ]
    
    // MARK: - English Strings
    private static let englishStrings: [String: String] = [
        // Common
        "done": "Done",
        "cancel": "Cancel",
        "reset": "Reset",
        "close": "Close",
        "version": "Version",
        "confirm": "OK",
        
        // Camera View
        "camera_preparing": "Preparing camera...",
        "camera_permission_denied": "Camera Access Required",
        "camera_permission_denied_desc": "Camera access is required for real-time translation. Please allow camera permission in Settings.",
        "translation_target": "Translation Target",
        "language_pack_auto_install": "Translation packs will be installed automatically when the language is detected during camera use",
        "language_pack_install_on_demand": "Translation pack installation popup will be shown when needed during translation attempts",
        "language_pack_installing": "Installing language pack...",
        "live_mode_paused_title": "Live Mode Paused",
        "live_mode_paused_message": "Live mode has been paused to save battery. Please reactivate when needed.",
        
        // Settings
        "settings": "Settings",
        "language_settings": "Language Settings",
        "target_language": "Target Language",
        "translation_mode": "Translation Mode",
        "on_device_mode": "On-Device Mode",
        "enabled": "Enabled",
        "disabled": "Disabled",
        "needs_on_device_mode": "On-Device Mode Required",
        "on_device_mode_required": "On-Device Mode Required",
        "on_device_mode_instruction_1": "1. Open iOS Settings > Translate",
        "on_device_mode_instruction_2": "2. Turn on 'On-Device Mode'",
        "on_device_mode_instruction_3": "3. Download required languages",
        "on_device_mode_alert_message": "Translation not working?\n\nIn iOS Settings > Translate:\n1. Enable 'On-Device Mode'\n2. Download required languages\n\nThis enables offline translation.",
        "open_settings": "Open Settings",
        "on_device_translation_instruction": "To use on-device translation:",
        "open_translation_settings": "Open Translation Settings",
        "information": "Information",
        "ios_minimum_version": "Minimum iOS Version",
        "ar_mode": "AR Mode",
        "ar_tracking_method": "AR Tracking Method",
        "reset_app_settings": "Reset App Settings",
        "reset_app_settings_message": "Reset app settings to defaults. Language packs must be managed in iOS Settings.",
        "language_pack_management": "Language Pack Management",
        "language_pack_manage_instruction": "To manage language packs:",
        "language_pack_manage_path": "Settings → Apps → Translate → Downloaded Languages",
        "language_pack_manage_description": "You can delete language packs from the list.",
        
        // Progress Messages (Simplified)
        "processing": "Processing...",
        "processing_complete": "Complete",
        "ocr_processing": "Recognizing text...",
        "translating": "Translating...",
        
        // AR Modes
        "ar_standard": "Standard 2D Tracking (Recommended)",
        "ar_arkit": "ARKit 3D Tracking (Experimental)",
        "arkit_live_only": "ARKit Mode: Live Translation Only",
        "arkit_experimental_note": "Experimental - May have lower accuracy",
        
        // Debug
        "debug_info": "Debug Info",
        "clear_logs": "Clear Logs",
        "language_packs": "Language Packs",
        "app_state": "App State",
        "logs": "Logs",
        "performance": "Performance",
        "language_pack_status": "Language Pack Status",
        "checking_status": "Checking status...",
        "translation_pack_installed": "Translation pack installed",
        "available_in_camera": "Available in camera",
        "installing": "Installing...",
        "not_supported": "Not supported"
    ]
    
    // MARK: - Japanese Strings
    private static let japaneseStrings: [String: String] = [
        // Common
        "done": "完了",
        "cancel": "キャンセル",
        "reset": "リセット",
        "close": "閉じる",
        "version": "バージョン",
        "confirm": "確認",
        
        // Camera View
        "camera_preparing": "カメラ準備中...",
        "camera_permission_denied": "カメラアクセスが必要です",
        "camera_permission_denied_desc": "リアルタイム翻訳のためにカメラアクセスが必要です。設定でカメラの許可を有効にしてください。",
        "translation_target": "翻訳対象言語",
        "language_pack_auto_install": "カメラ使用中に該当言語が検出されると必要な翻訳パックが自動的にインストールされます",
        "language_pack_install_on_demand": "翻訳実行時に必要な場合、翻訳パックインストールポップアップが表示されます",
        "language_pack_installing": "言語パックインストール中...",
        "live_mode_paused_title": "ライブモード一時停止",
        "live_mode_paused_message": "バッテリー節約のためライブモードが一時停止されました。必要に応じて再度有効にしてください。",
        
        // Settings
        "settings": "設定",
        "language_settings": "言語設定",
        "target_language": "翻訳先言語",
        "translation_mode": "翻訳モード",
        "on_device_mode": "オンデバイスモード",
        "enabled": "有効",
        "disabled": "無効",
        "needs_on_device_mode": "オンデバイスモード必要",
        "on_device_mode_required": "オンデバイスモード必要",
        "on_device_mode_instruction_1": "1. iOS設定 > 翻訳を開く",
        "on_device_mode_instruction_2": "2. 'オンデバイスモード'をオンにする",
        "on_device_mode_instruction_3": "3. 必要な言語をダウンロード",
        "on_device_mode_alert_message": "翻訳が動作しませんか？\n\niOS設定 > 翻訳で：\n1. 'オンデバイスモード'を有効化\n2. 必要な言語をダウンロード\n\nこれによりオフライン翻訳が可能になります。",
        "open_settings": "設定を開く",
        "on_device_translation_instruction": "オンデバイス翻訳を使用するには：",
        "open_translation_settings": "翻訳設定を開く",
        "information": "情報",
        "ios_minimum_version": "iOS最小バージョン",
        "ar_mode": "ARモード",
        "ar_tracking_method": "AR追跡方式",
        "reset_app_settings": "アプリ設定リセット",
        "reset_app_settings_message": "アプリ設定をデフォルトに戻します。言語パックはiOS設定で直接管理する必要があります。",
        "language_pack_management": "言語パック管理",
        "language_pack_manage_instruction": "言語パックを管理するには：",
        "language_pack_manage_path": "設定 → アプリ → 翻訳 → ダウンロード済み言語",
        "language_pack_manage_description": "リストから言語パックを削除できます。",
        
        // Progress Messages (Simplified)
        "processing": "処理中...",
        "processing_complete": "完了",
        "ocr_processing": "テキスト認識中...",
        "translating": "翻訳中...",
        
        // AR Modes
        "ar_standard": "標準2D追跡（推奨）",
        "ar_arkit": "ARKit 3D追跡（実験的）",
        "arkit_live_only": "ARKitモード: リアルタイム翻訳のみ",
        "arkit_experimental_note": "実験的機能 - 精度が低い場合があります",
        
        // Debug
        "debug_info": "デバッグ情報",
        "clear_logs": "ログクリア",
        "language_packs": "言語パック",
        "app_state": "アプリ状態",
        "logs": "ログ",
        "performance": "パフォーマンス",
        "language_pack_status": "言語パックステータス",
        "checking_status": "ステータス確認中...",
        "translation_pack_installed": "翻訳パックインストール済み",
        "available_in_camera": "カメラで利用可能",
        "installing": "インストール中...",
        "not_supported": "サポートされていません"
    ]
    
    // MARK: - Public Methods
    
    /// Get the system language code
    static func getSystemLanguage() -> String {
        // Get the first preferred language from iOS settings
        guard let preferredLanguage = Locale.preferredLanguages.first else {
            return "en" // Default to English
        }
        
        // Extract the language code (e.g., "ko-KR" -> "ko")
        let languageCode = String(preferredLanguage.prefix(2))
        
        // Map to our supported languages
        switch languageCode {
        case "ko":
            return "ko"
        case "ja":
            return "ja"
        default:
            return "en" // Default to English for all other languages
        }
    }
    
    /// Get localized string for the given key and language
    static func localizedString(_ key: String, for language: String) -> String {
        switch language {
        case "en":
            return englishStrings[key] ?? koreanStrings[key] ?? key
        case "ja":
            return japaneseStrings[key] ?? koreanStrings[key] ?? key
        default: // "ko" or any other
            return koreanStrings[key] ?? key
        }
    }
    
    /// Get localized string using system language (for UI elements)
    static func L(_ key: String) -> String {
        let systemLanguage = getSystemLanguage()
        return localizedString(key, for: systemLanguage)
    }
    
    /// Get localized string for specific language (for translation target labels)
    static func L(_ key: String, _ targetLanguage: String) -> String {
        return localizedString(key, for: targetLanguage)
    }
}