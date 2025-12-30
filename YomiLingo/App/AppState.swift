//
//  AppState.swift
//  ViewLingo-Cam
//
//  Global app state management
//

import SwiftUI
import Combine

// MARK: - AR Mode

enum ARMode: String, CaseIterable {
    case standard = "Standard"  // Combined Legacy + Enhanced
    case arkit = "ARKit"
    
    var description: String {
        // Use system language for UI display
        return localizedDescription()
    }
    
    func localizedDescription() -> String {
        // Use system language for UI elements
        switch self {
        case .standard: return LocalizationService.L("ar_standard")
        case .arkit: return LocalizationService.L("ar_arkit")
        }
    }
    
    func localizedDescription(for language: String) -> String {
        // Keep this for cases where we need specific language (for backward compatibility)
        switch self {
        case .standard: return LocalizationService.L("ar_standard", language)
        case .arkit: return LocalizationService.L("ar_arkit", language)
        }
    }
}

@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties
    
    @Published var targetLanguage: String = "ko"  // Default target language
    @Published var sourceLanguage: String = "auto"  // Source language for OCR
    @Published var arMode: ARMode = .standard  // AR mode selection (default: stable standard mode)
    @Published var isLiveTranslationEnabled: Bool? = false  // Live translation mode
    @Published var enabledSourceLanguages: Set<String> = []  // Enabled source languages for translation
    
    // MARK: - Private Properties
    
    private let userDefaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    
    // UserDefaults Keys
    private enum Keys {
        static let targetLanguage = "VLC.TargetLanguage"
        static let arMode = "VLC.ARMode"
        static let enabledSourceLanguages = "VLC.EnabledSourceLanguages"
    }
    
    // Supported target languages (for translation TO)
    let supportedLanguages = [
        ("ko", "한국어", "🇰🇷"),
        ("en", "English", "🇺🇸"),
        ("ja", "日本語", "🇯🇵")
    ]
    
    // Available source languages (for translation FROM)
    let availableSourceLanguages = [
        ("ko", "한국어", "🇰🇷"),
        ("en", "English", "🇺🇸"),
        ("ja", "日本語", "🇯🇵"),
        ("fr", "Français", "🇫🇷")
    ]
    
    // MARK: - Initialization
    
    init() {
        loadState()
        setupObservers()
    }
    
    // MARK: - Public Methods
    
    func loadState() {
        targetLanguage = userDefaults.string(forKey: Keys.targetLanguage) ?? detectBestTargetLanguage()
        
        // Load AR mode
        if let arModeString = userDefaults.string(forKey: Keys.arMode),
           let mode = ARMode(rawValue: arModeString) {
            arMode = mode
        }
        
        // Load enabled source languages or set defaults
        if let savedSources = userDefaults.array(forKey: Keys.enabledSourceLanguages) as? [String] {
            enabledSourceLanguages = Set(savedSources)
        } else {
            // Set default source languages based on target
            enabledSourceLanguages = getDefaultSourceLanguages(for: targetLanguage)
        }
        
        Logger.shared.log(.info, """
            📱 App State Loaded:
              - Target Language: \(targetLanguage)
              - AR Mode: \(arMode.rawValue)
              - Enabled Sources: \(enabledSourceLanguages.sorted().joined(separator: ", "))
            """)
    }
    
    // Onboarding method removed - no longer needed
    
    func setTargetLanguage(_ language: String) {
        guard supportedLanguages.contains(where: { $0.0 == language }) else { return }
        targetLanguage = language
        userDefaults.set(language, forKey: Keys.targetLanguage)
        
        // Reset source languages to defaults for new target
        enabledSourceLanguages = getDefaultSourceLanguages(for: language)
        userDefaults.set(Array(enabledSourceLanguages), forKey: Keys.enabledSourceLanguages)
        
        Logger.shared.log(.info, "Target language changed to: \(language), sources: \(enabledSourceLanguages.sorted())")
    }
    
    func setEnabledSourceLanguages(_ languages: Set<String>) {
        // Ensure at least one source language is enabled
        guard !languages.isEmpty else { return }
        
        // Ensure target language is not in source languages
        let filteredLanguages = languages.filter { $0 != targetLanguage }
        guard !filteredLanguages.isEmpty else { return }
        
        enabledSourceLanguages = Set(filteredLanguages)
        userDefaults.set(Array(enabledSourceLanguages), forKey: Keys.enabledSourceLanguages)
        
        Logger.shared.log(.info, "Enabled source languages changed to: \(enabledSourceLanguages.sorted())")
    }
    
    func toggleSourceLanguage(_ language: String) {
        // Can't toggle target language
        guard language != targetLanguage else { return }
        
        if enabledSourceLanguages.contains(language) {
            // Don't remove if it's the last one
            guard enabledSourceLanguages.count > 1 else { return }
            enabledSourceLanguages.remove(language)
        } else {
            enabledSourceLanguages.insert(language)
        }
        
        userDefaults.set(Array(enabledSourceLanguages), forKey: Keys.enabledSourceLanguages)
        Logger.shared.log(.info, "Source language \(language) toggled, now: \(enabledSourceLanguages.sorted())")
    }
    
    func setARMode(_ mode: ARMode) {
        arMode = mode
        userDefaults.set(mode.rawValue, forKey: Keys.arMode)
        Logger.shared.log(.info, "AR mode changed to: \(mode.rawValue)")
    }
    
    func resetForTesting() {
        targetLanguage = detectBestTargetLanguage()
        arMode = .standard
        
        userDefaults.removeObject(forKey: Keys.targetLanguage)
        userDefaults.removeObject(forKey: Keys.arMode)
        
        Logger.shared.log(.warning, "App state reset for testing")
    }
    
    func getLanguageInfo(for code: String) -> (code: String, name: String, emoji: String)? {
        return supportedLanguages.first { $0.0 == code }
    }
    
    // MARK: - Private Methods
    
    private func saveState() {
        userDefaults.set(targetLanguage, forKey: Keys.targetLanguage)
        userDefaults.set(arMode.rawValue, forKey: Keys.arMode)
    }
    
    private func setupObservers() {
        // Auto-save when properties change
        $targetLanguage
            .dropFirst()
            .sink { [weak self] _ in
                self?.saveState()
            }
            .store(in: &cancellables)
        
        $arMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.saveState()
            }
            .store(in: &cancellables)
    }
    
    private func getDefaultSourceLanguages(for targetLanguage: String) -> Set<String> {
        // Return all available languages except the target (excluding French by default)
        switch targetLanguage {
        case "ko":
            return ["en", "ja"]  // Default: English and Japanese
        case "en":
            return ["ko", "ja"]  // Default: Korean and Japanese
        case "ja":
            return ["ko", "en"]  // Default: Korean and English
        default:
            // Fallback: all languages except target and French
            return Set(["ko", "en", "ja"].filter { $0 != targetLanguage })
        }
    }
    
    private func detectBestTargetLanguage() -> String {
        let systemLang = Locale.current.language.languageCode?.identifier ?? "en"
        
        // Choose a different language than system for translation
        switch systemLang {
        case "ko": return "en"  // Korean users likely want English
        case "ja": return "ko"  // Japanese users likely want Korean
        case "en": return "ko"  // English users likely want Korean
        default: return "ko"     // Default to Korean
        }
    }
}