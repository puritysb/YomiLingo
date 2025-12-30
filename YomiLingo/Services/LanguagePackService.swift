//
//  LanguagePackService.swift
//  ViewLingo-Cam
//
//  Manages language pack installation and availability
//  CRITICAL: Never triggers downloads in camera mode
//

import SwiftUI
import Translation

@available(iOS 18.0, *)
@MainActor
class LanguagePackService: ObservableObject {
    // MARK: - Singleton
    
    static let shared = LanguagePackService()
    
    // MARK: - Types
    
    struct LanguagePair: Hashable {
        let source: String  // NEVER nil - explicit pairs only!
        let target: String
        
        var key: String {
            "\(source)→\(target)"
        }
    }
    
    enum PackStatus {
        case checking
        case notInstalled
        case installed
        case unsupported
    }
    
    // MARK: - Published Properties
    
    @Published var packStatuses: [LanguagePair: PackStatus] = [:]
    @Published var isCheckingStatus = false
    
    // MARK: - Private Properties
    
    private let availability = LanguageAvailability()
    private let supportedLanguages = ["ko", "en", "ja"]
    private var sessionValidationCache: [String: Bool] = [:]  // Cache session validation results
    
    // MARK: - Initialization
    
    private init() {
        Logger.shared.log(.info, "LanguagePackService initialized")
        
        // Listen for app foreground to refresh statuses
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Refresh all cached statuses
                for pair in self.packStatuses.keys {
                    await self.checkPairStatus(from: pair.source, to: pair.target)
                }
                Logger.shared.log(.info, "Refreshed language pack statuses after returning to foreground")
            }
        }
    }
    
    // MARK: - Status Checking (No Downloads)
    
    /// Check if translation is possible WITHOUT triggering downloads
    func canTranslate(from source: String, to target: String) -> Bool {
        // Never allow same language translation
        if source == target {
            return false
        }
        
        // Check cached status
        let pair = LanguagePair(source: source, target: target)
        
        // If we have a cached status, use it
        if let status = packStatuses[pair] {
            return status == .installed
        }
        
        // Default to false in camera mode (no checking that might trigger popups)
        return false
    }
    
    /// Check all language pair statuses (call only from onboarding)
    func checkAllStatuses() async {
        Logger.shared.log(.info, "Checking all language pack statuses...")
        isCheckingStatus = true
        
        // Check bidirectional language pairs (NO auto-detect)
        // Korean as target (bidirectional)
        await checkPairStatus(from: "en", to: "ko")
        await checkPairStatus(from: "ja", to: "ko")
        await checkPairStatus(from: "ko", to: "en")  // Reverse direction
        await checkPairStatus(from: "ko", to: "ja")  // Reverse direction
        
        // English as target (bidirectional)
        await checkPairStatus(from: "ko", to: "en")
        await checkPairStatus(from: "ja", to: "en")
        await checkPairStatus(from: "en", to: "ko")  // Reverse direction
        await checkPairStatus(from: "en", to: "ja")  // Reverse direction
        
        // Japanese as target (bidirectional)
        await checkPairStatus(from: "ko", to: "ja")
        await checkPairStatus(from: "en", to: "ja")
        await checkPairStatus(from: "ja", to: "ko")  // Reverse direction
        await checkPairStatus(from: "ja", to: "en")  // Reverse direction
        
        isCheckingStatus = false
        logStatusSummary()
    }
    
    /// Check status for specific target language (onboarding only)
    func checkStatusForTarget(_ target: String) async {
        Logger.shared.log(.info, "Checking language packs for target: \(target)")
        
        // Check only explicit pairs for this target (NO auto-detect)
        let requiredPairs = getRequiredPairs(for: target)
        for pair in requiredPairs {
            // Use pair.target instead of target to get correct target language
            await checkPairStatus(from: pair.source, to: pair.target)
        }
    }
    
    // MARK: - Installation (Onboarding Only)
    
    /// Get required language pairs for a target language (bidirectional)
    func getRequiredPairs(for targetLanguage: String) -> [LanguagePair] {
        var pairs: [LanguagePair] = []
        
        // NO auto-detect! Only explicit language pairs (bidirectional support)
        switch targetLanguage {
        case "ko":
            // Korean as target: All other languages to Korean + Korean to all others
            pairs.append(LanguagePair(source: "en", target: "ko"))
            pairs.append(LanguagePair(source: "ja", target: "ko"))
            // Bidirectional: Korean to other languages
            pairs.append(LanguagePair(source: "ko", target: "en"))
            pairs.append(LanguagePair(source: "ko", target: "ja"))
            
        case "en":
            // English as target: All other languages to English + English to all others
            pairs.append(LanguagePair(source: "ko", target: "en"))
            pairs.append(LanguagePair(source: "ja", target: "en"))
            // Bidirectional: English to other languages
            pairs.append(LanguagePair(source: "en", target: "ko"))
            pairs.append(LanguagePair(source: "en", target: "ja"))
            
        case "ja":
            // Japanese as target: All other languages to Japanese + Japanese to all others
            pairs.append(LanguagePair(source: "ko", target: "ja"))
            pairs.append(LanguagePair(source: "en", target: "ja"))
            // Bidirectional: Japanese to other languages
            pairs.append(LanguagePair(source: "ja", target: "ko"))
            pairs.append(LanguagePair(source: "ja", target: "en"))
            
        default:
            Logger.shared.log(.warning, "Unsupported target language: \(targetLanguage)")
        }
        
        Logger.shared.log(.info, "Required pairs for \(targetLanguage): \(pairs.map { $0.key }.joined(separator: ", "))")
        return pairs
    }
    
    /// Check if all required pairs are installed for a target language
    func areRequiredPacksInstalled(for targetLanguage: String) -> Bool {
        let requiredPairs = getRequiredPairs(for: targetLanguage)
        
        for pair in requiredPairs {
            if packStatuses[pair] != .installed {
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Private Methods
    
    private func checkPairStatus(from source: String, to target: String) async {
        let pair = LanguagePair(source: source, target: target)
        
        // Update to checking
        packStatuses[pair] = .checking
        
        // Create language objects (source is never nil now)
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        
        // Check availability
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        
        // Update status
        switch status {
        case .installed:
            packStatuses[pair] = .installed
            Logger.shared.logLanguagePack("status", pair.key, "Installed ✅")
            
        case .supported:
            packStatuses[pair] = .notInstalled
            Logger.shared.logLanguagePack("status", pair.key, "Available but not installed 📦")
            
        case .unsupported:
            packStatuses[pair] = .unsupported
            Logger.shared.logLanguagePack("status", pair.key, "Not supported ❌")
            
        @unknown default:
            packStatuses[pair] = .unsupported
            Logger.shared.logLanguagePack("status", pair.key, "Unknown status ⚠️")
        }
    }
    
    private func logStatusSummary() {
        let installed = packStatuses.filter { $0.value == .installed }.count
        let notInstalled = packStatuses.filter { $0.value == .notInstalled }.count
        let unsupported = packStatuses.filter { $0.value == .unsupported }.count
        
        Logger.shared.log(.info, """
            Language Pack Summary:
              - Installed: \(installed)
              - Not Installed: \(notInstalled)
              - Unsupported: \(unsupported)
            """)
    }
    
    /// Mark a session as validated and working
    func markSessionValidated(source: String, target: String) {
        let key = "\(source)→\(target)"
        sessionValidationCache[key] = true
        
        // Update pack status
        let pair = LanguagePair(source: source, target: target)
        packStatuses[pair] = .installed
        
        Logger.shared.log(.info, "✅ Session validated and marked as installed: \(key)")
    }
    
    /// Check if we have enough validated sessions for translation
    func hasMinimumSessionsForTarget(_ target: String) -> Bool {
        let requiredPairs = getRequiredPairs(for: target)
        let validatedCount = requiredPairs.filter { pair in
            sessionValidationCache[pair.key] == true
        }.count
        
        // Need at least 2 sessions for basic translation
        let hasMinimum = validatedCount >= 2
        
        Logger.shared.log(.debug, """
            Session validation for target \(target):
              - Required pairs: \(requiredPairs.count)
              - Validated: \(validatedCount)
              - Has minimum: \(hasMinimum)
            """)
        
        return hasMinimum
    }
    
    /// Get missing language pairs for a target
    func getMissingPairs(for target: String) -> [LanguagePair] {
        let requiredPairs = getRequiredPairs(for: target)
        return requiredPairs.filter { pair in
            sessionValidationCache[pair.key] != true
        }
    }
}

// MARK: - Helper Extensions

@available(iOS 18.0, *)
extension LanguagePackService {
    /// Get display name for language code
    func getLanguageName(_ code: String) -> String {
        switch code {
        case "ko": return "한국어"
        case "en": return "English"
        case "ja": return "日本語"
        case "fr": return "Français"
        default: return code.uppercased()
        }
    }
    
    /// Get emoji for language code
    func getLanguageEmoji(_ code: String) -> String {
        switch code {
        case "ko": return "🇰🇷"
        case "en": return "🇺🇸"
        case "ja": return "🇯🇵"
        case "fr": return "🇫🇷"
        default: return "🌐"
        }
    }
}