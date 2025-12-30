//
//  TranslationService.swift
//  ViewLingo-Cam
//
//  Camera mode translation service that NEVER triggers popups
//

import SwiftUI
import Translation
import NaturalLanguage

@available(iOS 18.0, *)
@MainActor
class TranslationService: ObservableObject {
    // MARK: - Published Properties
    
    @Published var isTranslating = false
    @Published var lastTranslationTime: TimeInterval = 0
    
    // Reference to app state for source language filtering
    weak var appState: AppState?
    
    // MARK: - Private Properties
    
    private var translationCache: [String: String] = [:]
    private let maxCacheSize = 200
    private let languageRecognizer = NLLanguageRecognizer()
    private let languageService = LanguagePackService.shared
    private var recentLanguageDetections: [(language: String, timestamp: Date)] = []  // Track recent detections
    var missingLanguagePacks: Set<String> = []  // Track missing language packs
    private var contextHint: String? = nil  // Context hint for better language detection
    
    // Translation sessions per language pair (created by view)
    private var translationSessions: [String: TranslationSession] = [:]  // key: "source→target"
    private var targetLanguage: String = "en"  // Current target language
    
    // MARK: - Initialization
    
    init() {
        Logger.shared.log(.info, "TranslationService initialized for camera mode")
    }
    
    // MARK: - Session Management
    
    /// Add a translation session for a specific language pair (called by CameraView)
    func addSession(_ session: TranslationSession?, source: String, target: String) {
        let key = "\(source)→\(target)"
        
        // Validate session before adding
        guard let session = session else {
            Logger.shared.log(.warning, "⚠️ Attempted to add nil session for \(key)")
            missingLanguagePacks.insert(key)
            return
        }
        
        // Store the session immediately
        translationSessions[key] = session
        missingLanguagePacks.remove(key)
        self.targetLanguage = target  // Update current target
        Logger.shared.log(.info, "✅ Translation session added: \(key)")
        
        // Remove from missing packs - assume it's ready after being added
        missingLanguagePacks.remove(key)
        
        // NOTE: prepareTranslation is now handled by DynamicLanguagePackProvider
        // The session should already be prepared when we receive it
        
        // Validate the session is working
        Task {
            await validateSession(session, key: key)
        }
    }
    
    /// Validate a session by attempting a test translation
    private func validateSession(_ session: TranslationSession, key: String) async {
        do {
            // Try a simple test translation
            let testText = key.starts(with: "ko") ? "테스트" : 
                          key.starts(with: "ja") ? "テスト" : "test"
            
            let request = TranslationSession.Request(sourceText: testText)
            let responses = try await session.translations(from: [request])
            
            if let translation = responses.first?.targetText, !translation.isEmpty {
                Logger.shared.log(.info, "✅ Session \(key) validated: '\(testText)' → '\(translation)'")
                // Remove from missing packs if it was there
                missingLanguagePacks.remove(key)
                
                // Mark as validated in LanguagePackService
                let components = key.split(separator: "→").map(String.init)
                if components.count == 2 {
                    languageService.markSessionValidated(source: components[0], target: components[1])
                }
            } else {
                Logger.shared.log(.warning, "⚠️ Session \(key) validation returned empty translation")
            }
        } catch {
            Logger.shared.log(.error, "❌ Session \(key) validation failed: \(error.localizedDescription)")
            // Mark this session as potentially problematic
            missingLanguagePacks.insert(key)
        }
    }
    
    /// Clear all sessions
    func clearSessions() {
        translationSessions.removeAll()
        missingLanguagePacks.removeAll()
    }
    
    /// Check if language pack is missing for a given source and target
    func isLanguagePackMissing(for source: String, target: String) -> Bool {
        let key = "\(source)→\(target)"
        return missingLanguagePacks.contains(key)
    }
    
    /// Get the count of available sessions
    func getSessionCount() -> Int {
        return translationSessions.count
    }
    
    /// Check if translation is available
    func canTranslate(to targetLanguage: String) -> Bool {
        // Check if we have sessions for the most common source languages
        let requiredSources = ["ko", "en", "ja"].filter { $0 != targetLanguage }
        let availableSessions = requiredSources.compactMap { source in
            let sessionKey = "\(source)→\(targetLanguage)"
            return translationSessions[sessionKey] != nil ? sessionKey : nil
        }
        
        let hasMinimumSessions = availableSessions.count >= 1 // At least one session available
        
        if !hasMinimumSessions {
            Logger.shared.log(.warning, """
                ⚠️ Insufficient translation sessions for target: \(targetLanguage)
                  - Required sources: \(requiredSources.joined(separator: ", "))
                  - Total sessions: \(translationSessions.count)
                  - All available sessions: \(translationSessions.keys.sorted().joined(separator: ", "))
                  - Sessions for target \(targetLanguage): \(availableSessions.joined(separator: ", "))
                  - Missing sessions: \(requiredSources.filter { source in !translationSessions.keys.contains("\(source)→\(targetLanguage)") }.map { "\($0)→\(targetLanguage)" }.joined(separator: ", "))
                """)
        } else {
            Logger.shared.log(.debug, "✅ Translation available for \(targetLanguage) with \(availableSessions.count) sessions: \(availableSessions.joined(separator: ", "))")
        }
        
        return hasMinimumSessions
    }
    
    /// Check if a specific language pair session is available
    func canTranslate(from sourceLanguage: String, to targetLanguage: String) -> Bool {
        let sessionKey = "\(sourceLanguage)→\(targetLanguage)"
        let hasSession = translationSessions[sessionKey] != nil
        
        if !hasSession {
            Logger.shared.log(.debug, "No session available for specific pair: \(sessionKey)")
        }
        
        return hasSession
    }
    
    /// Get available session count for debugging
    func getAvailableSessionsInfo() -> String {
        return """
            Available sessions (\(translationSessions.count)):
            \(translationSessions.keys.sorted().joined(separator: ", "))
            """
    }
    
    // MARK: - Text Cleaning
    
    /// Clean text before translation to remove noise
    private func cleanTextForTranslation(_ text: String) -> String {
        // Remove broken/replacement characters
        var cleaned = text.replacingOccurrences(of: "￿", with: "")
        
        // Remove consecutive special characters (bullets, dots, etc.)
        cleaned = cleaned.replacingOccurrences(of: "[•·]{2,}", with: "", options: .regularExpression)
        
        // Only remove control characters, preserve meaningful special characters
        // This allows @, #, $, %, &, *, /, : etc. to be preserved in meaningful text
        cleaned = cleaned.replacingOccurrences(of: "[\\p{C}]+", with: " ", options: .regularExpression)
        
        // Collapse multiple spaces
        cleaned = cleaned.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Clean translation result to remove unwanted characters
    private func cleanTranslationResult(_ translation: String) -> String {
        // Define allowed characters (expanded to include common special characters)
        var allowedChars = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)
            // Extended special characters for URLs, emails, currency, math, etc.
            .union(CharacterSet(charactersIn: ".,!?:;()[]{}\"'-|@#$%&*+=/<>\\^_`~¥£€₩"))
        
        // Add CJK punctuation
        let cjkPunctuation = CharacterSet(charactersIn: "。、！？「」『』（）【】")
        allowedChars = allowedChars.union(cjkPunctuation)
        
        // Filter out unwanted characters
        let cleaned = translation.unicodeScalars
            .filter { allowedChars.contains($0) }
            .map { String($0) }
            .joined()
        
        // Remove any remaining broken characters
        return cleaned.replacingOccurrences(of: "￿", with: "")
    }
    
    // MARK: - Translation
    
    /// Translate texts with context hint for better language detection
    func translateTextsWithContext(_ texts: [String], targetLanguage: String, contextHint: String?) async -> [String: String] {
        // Store context hint for use in language detection
        self.contextHint = contextHint
        let result = await translateTexts(texts, targetLanguage: targetLanguage)
        self.contextHint = nil  // Clear context after use
        return result
    }
    
    /// Translate texts using appropriate sessions (NO POPUP TRIGGERS)
    func translateTexts(_ texts: [String], targetLanguage: String) async -> [String: String] {
        // Filter out empty texts and clean them
        let validTexts = texts.compactMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            
            // Clean the text before validation
            let cleaned = cleanTextForTranslation(trimmed)
            return cleaned.isEmpty ? nil : cleaned
        }
        
        // Additional pre-translation validation
        let cleanTexts = validTexts.filter { text in
            // For CJK texts, allow even single characters (like 年, 月, etc.)
            let hasCJK = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}\u{ac00}-\u{d7af}]", options: .regularExpression) != nil
            
            // Skip texts that are too short (likely noise) - but allow short CJK texts
            let minLength = hasCJK ? 1 : 2
            guard text.count >= minLength else {
                Logger.shared.log(.debug, "Skipping too short text: '\(text)'")
                return false
            }
            
            // Skip pure numbers (1-2 digits) or pure punctuation/symbols
            let letterCount = text.filter { $0.isLetter }.count
            let numberCount = text.filter { $0.isNumber }.count
            
            // Skip if it's only 1-2 digit numbers with no letters
            if letterCount == 0 && numberCount <= 2 {
                Logger.shared.log(.debug, "Skipping pure number text: '\(text)'")
                return false
            }
            
            // Skip if no alphanumeric characters at all
            let hasAnyAlphanumeric = letterCount > 0 || numberCount > 0
            guard hasAnyAlphanumeric else {
                Logger.shared.log(.debug, "Skipping pure symbol text: '\(text)'")
                return false
            }
            
            // Allow text with letters (like "AUG") or longer numbers/mixed content (like "2024")
            
            // Skip known OCR noise patterns
            let noisePatterns = [
                "^[i•]+[0-9]+",
                "^[y)]+$",
                "^[il1•][^a-zA-Z]*$"
            ]
            for pattern in noisePatterns {
                if text.range(of: pattern, options: .regularExpression) != nil {
                    Logger.shared.log(.debug, "Skipping noise pattern: '\(text)'")
                    return false
                }
            }
            
            return true
        }
        
        guard !cleanTexts.isEmpty else { 
            Logger.shared.log(.debug, "No valid texts to translate after filtering")
            return [:] 
        }
        
        Logger.shared.log(.debug, "Processing \(cleanTexts.count) texts for translation to \(targetLanguage)")
        
        // Group texts by detected source language
        var textsByLanguage: [String: [String]] = [:]
        var skippedCount = 0
        var undetectedTexts: [String] = []
        var possiblyMisdetectedTexts: [String] = []  // Texts detected as target language but might be wrong
        
        for text in cleanTexts {
            let preview = String(text.prefix(30))
            // Pass targetLanguage for better detection accuracy
            if let detectedLang = detectLanguage(for: text, targetLanguage: targetLanguage) {
                Logger.shared.log(.debug, "Text '\(preview)...' detected as: \(detectedLang)")
                
                // For texts detected as same language, check if it might be misdetected
                if detectedLang == targetLanguage {
                    // Check if text looks garbled or has OCR artifacts
                    let hasNumbers = text.contains(where: { $0.isNumber })
                    let hasUppercase = text.contains(where: { $0.isUppercase })
                    let isShort = text.count < 10
                    let hasSymbols = text.contains(where: { !$0.isLetter && !$0.isWhitespace && !$0.isNumber })
                    
                    // If text looks suspicious, try translation anyway
                    if (hasNumbers && hasUppercase) || (isShort && hasSymbols) || text.contains("O1") || text.contains("l1") {
                        Logger.shared.log(.debug, "🔄 Suspicious text detected as \(detectedLang), will attempt translation: '\(preview)...'")
                        possiblyMisdetectedTexts.append(text)
                    } else {
                        Logger.shared.log(.debug, "⏭️ Skipping: same language (\(detectedLang) → \(targetLanguage))")
                        skippedCount += 1
                        continue
                    }
                }
                textsByLanguage[detectedLang, default: []].append(text)
            } else {
                Logger.shared.log(.debug, "❓ Could not detect language for: '\(preview)...' (target: \(targetLanguage))")
                undetectedTexts.append(text)
            }
        }
        
        // Try to detect language from combined undetected texts
        if !undetectedTexts.isEmpty {
            let combinedText = undetectedTexts.joined(separator: " ")
            // Pass targetLanguage for better detection accuracy
            if let dominantLang = detectLanguage(for: combinedText, targetLanguage: targetLanguage) {
                Logger.shared.log(.info, "Detected dominant language from combined texts: \(dominantLang)")
                if dominantLang != targetLanguage {
                    textsByLanguage[dominantLang, default: []].append(contentsOf: undetectedTexts)
                } else {
                    // Even if detected as target language, try translation for undetected texts
                    possiblyMisdetectedTexts.append(contentsOf: undetectedTexts)
                }
            } else {
                // As last resort, try to detect from all valid texts combined
                if let dominantLang = detectDominantLanguage(from: cleanTexts, targetLanguage: targetLanguage) {
                    Logger.shared.log(.info, "Using dominant language from all texts: \(dominantLang)")
                    if dominantLang != targetLanguage {
                        textsByLanguage[dominantLang, default: []].append(contentsOf: undetectedTexts)
                    } else {
                        // Try translation anyway for undetected texts
                        possiblyMisdetectedTexts.append(contentsOf: undetectedTexts)
                    }
                } else {
                    // No language detected - try with most likely source language
                    let guessedSource = targetLanguage == "en" ? "ja" : "en"
                    Logger.shared.log(.info, "No language detected, guessing source: \(guessedSource)")
                    textsByLanguage[guessedSource, default: []].append(contentsOf: undetectedTexts)
                }
            }
        }
        
        // Add possibly misdetected texts to try translation with different source languages
        if !possiblyMisdetectedTexts.isEmpty {
            // Try with the most likely alternative source language
            let alternativeSource = targetLanguage == "en" ? "ja" : (targetLanguage == "ko" ? "en" : "ko")
            Logger.shared.log(.info, "Will attempt translation for \(possiblyMisdetectedTexts.count) possibly misdetected texts with source: \(alternativeSource)")
            textsByLanguage[alternativeSource, default: []].append(contentsOf: possiblyMisdetectedTexts)
        }
        
        Logger.shared.log(.info, """
            Language detection summary:
              - Total texts: \(validTexts.count)
              - Skipped (same language): \(skippedCount)
              - Initially undetected: \(undetectedTexts.count)
              - To translate: \(textsByLanguage.values.map { $0.count }.reduce(0, +))
              - Languages found: \(textsByLanguage.keys.joined(separator: ", "))
            """)
        
        // No texts to translate
        guard !textsByLanguage.isEmpty else {
            Logger.shared.log(.debug, "No texts require translation after language detection")
            return [:]
        }
        
        isTranslating = true
        defer { isTranslating = false }
        
        let startTime = Date()
        var results: [String: String] = [:]
        
        // Log available sessions
        Logger.shared.log(.debug, "Available sessions: \(translationSessions.keys.joined(separator: ", "))")
        
        // Translate each language group with its specific session
        for (sourceLang, textsInLang) in textsByLanguage {
            // Filter by enabled source languages if appState is available
            if let appState = appState {
                guard appState.enabledSourceLanguages.contains(sourceLang) else {
                    Logger.shared.log(.info, "⏭️ Skipping disabled source language: \(sourceLang) with \(textsInLang.count) texts")
                    continue
                }
            }
            
            let sessionKey = "\(sourceLang)→\(targetLanguage)"
            
            // Check if we have a session for this language pair
            guard let session = translationSessions[sessionKey] else {
                Logger.shared.log(.warning, """
                    ❌ Translation session missing:
                      - Required pair: \(sessionKey)
                      - Available sessions: \(translationSessions.keys.sorted().joined(separator: ", "))
                      - Texts affected: \(textsInLang.count) (\(textsInLang.map { "'\($0.prefix(15))...'" }.joined(separator: ", ")))
                    """)
                continue
            }
            
            Logger.shared.log(.info, "Using session \(sessionKey) to translate \(textsInLang.count) texts")
            
            // Enhanced debug logging for text details
            for (index, text) in textsInLang.enumerated() {
                Logger.shared.log(.debug, "  [\(index + 1)] '\(text.prefix(30))\(text.count > 30 ? "..." : "")' (length: \(text.count))")
            }
            
            // Check cache first
            var textsToTranslate: [String] = []
            for text in textsInLang {
                let cacheKey = getCacheKey(text: text, source: sourceLang, target: targetLanguage)
                if let cached = translationCache[cacheKey] {
                    results[text] = cached
                } else {
                    textsToTranslate.append(text)
                }
            }
            
            // Translate uncached texts
            if !textsToTranslate.isEmpty {
                do {
                    // Create batch requests
                    let requests = textsToTranslate.map { text in
                        TranslationSession.Request(sourceText: text)
                    }
                    
                    // Perform translation with retry on failure
                    var responses: [TranslationSession.Response] = []
                    var retryCount = 0
                    let maxRetries = 2
                    
                    while retryCount <= maxRetries {
                        do {
                            responses = try await session.translations(from: requests)
                            // If we got here, translation succeeded
                            missingLanguagePacks.remove(sessionKey)  // Remove from missing if it worked
                            break
                        } catch {
                            retryCount += 1
                            
                            // Check for Error Code 16 (offline model unavailable)
                            if error.localizedDescription.contains("Code=16") || 
                               error.localizedDescription.contains("오프라인 모델을 사용할 수 없음") ||
                               error.localizedDescription.contains("internalError") {
                                
                                Logger.shared.log(.error, "❌ Language pack issue for \(sessionKey): \(error.localizedDescription)")
                                
                                // On first attempt, try to prepare the session
                                if retryCount == 1 {
                                    Logger.shared.log(.info, "🔄 Attempting to prepare session \(sessionKey)...")
                                    
                                    do {
                                        // This might trigger iOS system UI if language pack is missing
                                        try await session.prepareTranslation()
                                        Logger.shared.log(.info, "✅ Session \(sessionKey) prepared, retrying translation...")
                                        
                                        // Wait a bit for the preparation to settle
                                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                                        
                                        // Try translation again
                                        responses = try await session.translations(from: requests)
                                        Logger.shared.log(.info, "✅ Translation succeeded after prepare for \(sessionKey)")
                                        break
                                    } catch let prepareError {
                                        Logger.shared.log(.error, "❌ Prepare failed for \(sessionKey): \(prepareError)")
                                        
                                        // Mark session as broken
                                        missingLanguagePacks.insert(sessionKey)
                                        
                                        // Don't retry further
                                        break
                                    }
                                } else {
                                    // On subsequent attempts, just mark as failed
                                    missingLanguagePacks.insert(sessionKey)
                                    break
                                }
                            }
                            
                            if retryCount <= maxRetries {
                                Logger.shared.log(.warning, "⚠️ Translation attempt \(retryCount)/\(maxRetries) failed for \(sessionKey): \(error)")
                                // Wait a bit before retry
                                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                            } else {
                                throw error // Final failure
                            }
                        }
                    }
                    
                    // Process responses
                    for response in responses {
                        let original = response.sourceText
                        var translated = response.targetText
                        
                        // Log raw translation result
                        Logger.shared.log(.debug, "Raw translation: '\(original.prefix(30))...' → '\(translated.prefix(50))...'")
                        
                        // Clean the translation result
                        let beforeClean = translated
                        translated = cleanTranslationResult(translated)
                        
                        if beforeClean != translated {
                            Logger.shared.log(.debug, "Translation cleaned: '\(beforeClean.prefix(50))...' → '\(translated.prefix(50))...'")
                        }
                        
                        // Only store non-empty cleaned translations
                        if !translated.isEmpty {
                            results[original] = translated
                            Logger.shared.log(.info, "✅ Translation stored: '\(original.prefix(30))...' → '\(translated.prefix(50))...'")
                        } else {
                            Logger.shared.log(.warning, "⚠️ Translation result was empty after cleaning for: '\(original.prefix(30))...' (raw: '\(response.targetText.prefix(50))...')")
                        }
                        
                        // Cache the result
                        let cacheKey = getCacheKey(text: original, source: sourceLang, target: targetLanguage)
                        addToCache(key: cacheKey, value: translated)
                    }
                    
                    Logger.shared.logTranslation(
                        source: sourceLang,
                        target: targetLanguage,
                        success: true,
                        texts: textsToTranslate.count
                    )
                    
                } catch {
                    // Log translation failure
                    Logger.shared.log(.error, """
                        ❌ Translation failed for session \(sessionKey):
                          - Error: \(error.localizedDescription)
                          - Texts count: \(textsToTranslate.count)
                          - Session pair: \(sessionKey)
                        """)
                    
                    // Mark as problematic session for internal tracking
                    self.missingLanguagePacks.insert(sessionKey)
                    
                    Logger.shared.logTranslation(
                        source: sourceLang,
                        target: targetLanguage,
                        success: false,
                        error: error
                    )
                }
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        lastTranslationTime = duration
        
        return results
    }
    
    // MARK: - Language Detection
    
    /// Detect language of text with target language awareness
    func detectLanguage(for text: String, targetLanguage: String? = nil) -> String? {
        // Skip very short texts (likely noise) - but allow short CJK texts if context hint is available
        if text.count < 2 && contextHint == nil {
            Logger.shared.log(.debug, "Text too short for language detection: '\(text)'")
            return nil
        }
        
        // Use context hint if available for ambiguous cases
        if let hint = contextHint {
            Logger.shared.log(.debug, "Using context hint: \(hint) for text: '\(text.prefix(20))...'")
        }
        
        // IMPORTANT: Check for CJK languages with improved accuracy
        // Count character types to make better decisions and prevent misidentification
        
        // Count character types for more accurate detection
        let koreanChars = text.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return (scalar >= 0xAC00 && scalar <= 0xD7A3) ||  // Hangul syllables
                   (scalar >= 0x3131 && scalar <= 0x318E) ||  // Hangul compatibility
                   (scalar >= 0x1100 && scalar <= 0x11FF)      // Hangul Jamo
        }.count
        
        let japaneseHiragana = text.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return scalar >= 0x3040 && scalar <= 0x309F
        }.count
        
        let japaneseKatakana = text.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return scalar >= 0x30A0 && scalar <= 0x30FF
        }.count
        
        let kanjiChars = text.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return scalar >= 0x4E00 && scalar <= 0x9FAF
        }.count
        
        let totalJapanese = japaneseHiragana + japaneseKatakana
        
        // 1. Pure Korean (no Japanese kana)
        if koreanChars > 0 && totalJapanese == 0 {
            Logger.shared.log(.debug, "Korean detected (hangul: \(koreanChars), no kana): '\(text.prefix(20))...'")
            recordLanguageDetection("ko")
            return "ko"
        }
        
        // 2. Pure Japanese (has kana, no Korean)
        if totalJapanese > 0 && koreanChars == 0 {
            Logger.shared.log(.debug, "Japanese detected (kana: \(totalJapanese), no hangul): '\(text.prefix(20))...'")
            recordLanguageDetection("ja")
            return "ja"
        }
        
        // 3. Mixed characters (likely OCR error) - decide based on ratio
        if koreanChars > 0 && totalJapanese > 0 {
            if koreanChars > totalJapanese * 2 {
                // Significantly more Korean
                Logger.shared.log(.debug, "Mixed CJK - Korean dominant (hangul: \(koreanChars) >> kana: \(totalJapanese)): '\(text.prefix(20))...'")
                recordLanguageDetection("ko")
                return "ko"
            } else if totalJapanese > koreanChars * 2 {
                // Significantly more Japanese
                Logger.shared.log(.debug, "Mixed CJK - Japanese dominant (kana: \(totalJapanese) >> hangul: \(koreanChars)): '\(text.prefix(20))...'")
                recordLanguageDetection("ja")
                return "ja"
            } else {
                // Similar amounts - use context or default to more likely based on target
                if targetLanguage == "en" {
                    // When translating to English, check recent detections
                    let recentJa = recentLanguageDetections.filter { 
                        $0.language == "ja" && Date().timeIntervalSince($0.timestamp) < 2.0 
                    }.count
                    let recentKo = recentLanguageDetections.filter { 
                        $0.language == "ko" && Date().timeIntervalSince($0.timestamp) < 2.0 
                    }.count
                    
                    if recentJa > recentKo {
                        Logger.shared.log(.debug, "Mixed CJK - choosing Japanese based on context: '\(text.prefix(20))...'")
                        recordLanguageDetection("ja")
                        return "ja"
                    } else {
                        Logger.shared.log(.debug, "Mixed CJK - choosing Korean based on context: '\(text.prefix(20))...'")
                        recordLanguageDetection("ko")
                        return "ko"
                    }
                }
            }
        }
        
        // 4. Kanji/Hanja only (no kana or hangul) - need context
        if kanjiChars > 0 && koreanChars == 0 && totalJapanese == 0 {
            // First check if we have a context hint
            if let hint = contextHint {
                if hint == "ja" {
                    // Also check if these are common Japanese kanji
                    if hasJapaneseKanji(in: text) {
                        Logger.shared.log(.debug, "Kanji text with Japanese context hint and common kanji: '\(text.prefix(20))...'")
                        recordLanguageDetection("ja")
                        return "ja"
                    }
                    Logger.shared.log(.debug, "Kanji text with Japanese context hint: '\(text.prefix(20))...'")
                    recordLanguageDetection("ja")
                    return "ja"
                } else if hint == "ko" {
                    Logger.shared.log(.debug, "Hanja text with Korean context hint: '\(text.prefix(20))...'")
                    recordLanguageDetection("ko")
                    return "ko"
                }
            }
            
            // Check if these are common Japanese kanji
            if hasJapaneseKanji(in: text) {
                Logger.shared.log(.debug, "Common Japanese kanji detected: '\(text.prefix(20))...'")
                recordLanguageDetection("ja")
                return "ja"
            }
            
            // Use recent context to decide
            let recentJa = recentLanguageDetections.filter { 
                $0.language == "ja" && Date().timeIntervalSince($0.timestamp) < 2.0 
            }.count
            let recentKo = recentLanguageDetections.filter { 
                $0.language == "ko" && Date().timeIntervalSince($0.timestamp) < 2.0 
            }.count
            
            if recentJa > recentKo {
                Logger.shared.log(.debug, "Kanji text - assuming Japanese (recent context): '\(text.prefix(20))...'")
                recordLanguageDetection("ja")
                return "ja"
            } else if recentKo > 0 {
                Logger.shared.log(.debug, "Hanja text - assuming Korean (recent context): '\(text.prefix(20))...'")
                recordLanguageDetection("ko")
                return "ko"
            } else {
                // Default to Japanese for Kanji-only
                Logger.shared.log(.debug, "Kanji text - defaulting to Japanese: '\(text.prefix(20))...'")
                recordLanguageDetection("ja")
                return "ja"
            }
        }
        
        // 3. Check for possible misrecognized Korean (OCR errors)
        // Common patterns when Korean is misread as English
        let possibleKoreanPatterns = [
            "oo.*EO",           // Common misread of Korean characters
            "[A-Z]{1}[a-z]*[0-9]+", // Mixed case with numbers (common OCR error)
            "^[A-Z][a-z]{0,2}$",    // Very short capitalized words might be Korean
            "JEM[0-9]+",        // Common pattern when Korean is misread
            "[A-Z]{2,3}[0-9]{3,}", // Letters followed by many numbers
            "^[O0Il1]+[0-9]+",  // OCR confusion between O/0, I/1, l/1
        ]
        
        var mightBeMisreadKorean = false
        for pattern in possibleKoreanPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                mightBeMisreadKorean = true
                break
            }
        }
        
        if mightBeMisreadKorean {
            // Don't rely heavily on context - just warn that it might be Korean
            Logger.shared.log(.debug, "Possibly misread Korean based on pattern: '\(text.prefix(20))...'")
            
            // When target is English and we suspect misread Korean, return nil to force translation
            if targetLanguage == "en" {
                Logger.shared.log(.debug, "Forcing translation attempt for suspected misread Korean")
                return nil  // This will cause the text to be attempted for translation
            }
            // Otherwise let NLLanguageRecognizer make the final decision
        }
        
        // 4. Check for French - special characters and patterns
        let frenchChars = text.filter { char in
            let frenchSpecialChars = "àâäèéêëïîôùûüÿçÀÂÄÈÉÊËÏÎÔÙÛÜŸÇœŒæÆ"
            return frenchSpecialChars.contains(char)
        }.count
        
        // Common French patterns
        let frenchPatterns = [
            "\\b(le|la|les|un|une|des|de|du|et|ou|est|dans|avec|pour|sur|par|que|qui|ne|pas|plus|tout|très|bien)\\b",
            "\\b(je|tu|il|elle|nous|vous|ils|elles)\\b",
            "\\b(ce|cette|ces|mon|ma|mes|ton|ta|tes|son|sa|ses)\\b"
        ]
        
        var hasFrenchPattern = false
        for pattern in frenchPatterns {
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                hasFrenchPattern = true
                break
            }
        }
        
        // If has French special characters or strong patterns, likely French
        if frenchChars > 0 || (hasFrenchPattern && text.count > 10) {
            // Need at least 2 French special chars or pattern with sufficient text
            if frenchChars >= 2 || (hasFrenchPattern && !text.contains(where: { 
                // Exclude if has CJK characters
                let scalar = $0.unicodeScalars.first?.value ?? 0
                return (scalar >= 0x3040 && scalar <= 0x9FAF) || (scalar >= 0xAC00 && scalar <= 0xD7AF)
            })) {
                Logger.shared.log(.debug, "French detected (special chars: \(frenchChars), patterns: \(hasFrenchPattern)): '\(text.prefix(20))...'")
                recordLanguageDetection("fr")
                return "fr"
            }
        }
        
        // 5. Finally check for English - but be VERY strict when target is English
        // When translating TO English, we want to avoid false English detection
        if text.range(of: "[a-zA-Z]{1,}", options: .regularExpression) != nil {
            // Check if it's likely garbled text (too many symbols/punctuation)
            let letters = text.filter { $0.isLetter }
            let numbers = text.filter { $0.isNumber }
            let symbols = text.filter { !$0.isLetter && !$0.isWhitespace && !$0.isNumber }
            let symbolRatio = Double(symbols.count) / Double(max(1, text.count))
            let alphanumericRatio = Double(letters.count + numbers.count) / Double(max(1, text.count))
            
            // More relaxed criteria: If more than 60% symbols OR less than 20% alphanumeric, it's likely garbled
            if symbolRatio > 0.6 || alphanumericRatio < 0.2 {
                Logger.shared.log(.debug, "Possibly garbled text (symbols: \(String(format: "%.1f", symbolRatio * 100))%, alphanumeric: \(String(format: "%.1f", alphanumericRatio * 100))%): '\(text.prefix(20))...'")
                // Don't immediately return nil - let it fall through to pattern matching
            }
            
            // CRITICAL: When target is English, be MUCH stricter about English detection
            // This prevents misidentifying OCR-garbled Korean/Japanese as English
            let isTargetEnglish = targetLanguage == "en"
            
            // Check for readable English patterns (common words or patterns)
            let commonEnglishPatterns = [
                "\\b(the|and|or|is|it|to|a|an|in|on|at|for|with|from|of|as|by|have|this|that|was|are|but|not|you|all|can|had|her|his|one|our|out|day|get|has|him|how|may|new|now|old|see|two|way|who|boy|did|its|let|put|say|she|too|use)\\b",
                "\\b[A-Z][a-z]+\\b",  // Capitalized words
                "\\b(com|org|net|edu|www)\\b",  // Domain patterns
                "\\b\\d{1,4}\\b",  // Numbers
                "[a-zA-Z]{3,}",  // Any word with 3+ letters
                "\\b[A-Z]{2,}\\b"  // Acronyms
            ]
            
            var hasEnglishPattern = false
            var patternCount = 0
            for pattern in commonEnglishPatterns {
                if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    hasEnglishPattern = true
                    patternCount += 1
                    // For target English, require multiple pattern matches
                    if !isTargetEnglish {
                        break
                    }
                }
            }
            
            // When target is English, be less strict - we want to translate more texts
            // Even if it looks like English, we should try translation
            if isTargetEnglish {
                // For target English, require only 1 pattern OR decent alphanumeric content
                // This ensures we try to translate more texts rather than skipping them
                if patternCount >= 1 && alphanumericRatio >= 0.4 {
                    // However, if it's clearly garbled, return nil to try translation anyway
                    if symbolRatio > 0.3 || text.count < 4 {
                        Logger.shared.log(.debug, "Ambiguous text when target=en, will attempt translation: '\(text.prefix(20))...'")
                        return nil  // Return nil to force translation attempt
                    }
                    Logger.shared.log(.debug, "English detected (relaxed for target=en, patterns: \(patternCount)): '\(text.prefix(20))...'")
                    recordLanguageDetection("en")
                    return "en"
                }
                // For ambiguous cases when target is English, return nil to try translation
                Logger.shared.log(.debug, "Ambiguous text for target=en, will attempt translation: '\(text.prefix(20))...'")
                return nil
            } else {
                // Normal English detection when target is NOT English
                if hasEnglishPattern && alphanumericRatio >= 0.5 {
                    Logger.shared.log(.debug, "English detected via pattern matching (letters: \(letters.count), patterns: \(hasEnglishPattern)): '\(text.prefix(20))...'")
                    recordLanguageDetection("en")
                    return "en"
                }
                
                // For text without clear patterns, only accept as English if it has substantial letter content
                if !hasEnglishPattern && letters.count >= 5 && alphanumericRatio >= 0.7 {
                    Logger.shared.log(.debug, "English detected via letter count (letters: \(letters.count), ratio: \(alphanumericRatio)): '\(text.prefix(20))...'")
                    recordLanguageDetection("en")
                    return "en"
                }
            }
        }
        
        // For OCR-garbled text that might be CJK, try to guess based on context
        // If we have recent CJK detections, assume this garbled text is also CJK
        let recentCJK = recentLanguageDetections.filter { detection in
            (detection.language == "ja" || detection.language == "ko") && 
            Date().timeIntervalSince(detection.timestamp) < 3.0
        }.count
        
        if recentCJK > 0 && text.contains(where: { !$0.isASCII }) {
            // Likely garbled CJK text
            let likelyLanguage = recentLanguageDetections.last?.language ?? "ja"
            Logger.shared.log(.debug, "Guessing \(likelyLanguage) for garbled text based on context: '\(text.prefix(20))...'")
            recordLanguageDetection(likelyLanguage)
            return likelyLanguage
        }
        
        // Fallback to NLLanguageRecognizer
        languageRecognizer.reset()
        languageRecognizer.processString(text)
        
        guard let language = languageRecognizer.dominantLanguage else {
            Logger.shared.log(.debug, "No dominant language detected for: '\(text.prefix(20))...'")
            return nil
        }
        
        // Check confidence
        let hypotheses = languageRecognizer.languageHypotheses(withMaximum: 3)
        let confidence = hypotheses[language] ?? 0.0
        
        // Log top hypotheses for debugging
        let topHypotheses = hypotheses.map { "\($0.key.rawValue): \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
        Logger.shared.log(.debug, "Language hypotheses for '\(text.prefix(20))...': \(topHypotheses)")
        
        // Require much lower confidence for all languages to improve detection
        // Japanese text often has very low confidence scores
        let minConfidence: Double
        if language.rawValue.hasPrefix("ja") {
            minConfidence = text.count < 10 ? 0.1 : 0.15  // Very low for Japanese
        } else if language.rawValue.hasPrefix("ko") {
            minConfidence = text.count < 10 ? 0.15 : 0.2  // Low for Korean
        } else {
            minConfidence = text.count < 10 ? 0.2 : 0.25  // Moderate for English
        }
        
        if confidence > minConfidence {
            // Map to our supported languages
            let langCode = language.rawValue
            switch langCode {
            case "ko", "ko-KR": 
                recordLanguageDetection("ko")
                return "ko"
            case "en", "en-US", "en-GB": 
                recordLanguageDetection("en")
                return "en"
            case "ja", "ja-JP": 
                recordLanguageDetection("ja")
                return "ja"
            case "fr", "fr-FR", "fr-CA":
                recordLanguageDetection("fr")
                return "fr"
            default: 
                Logger.shared.log(.debug, "Unsupported language detected: \(langCode)")
                return nil
            }
        }
        
        Logger.shared.log(.debug, "Low confidence (\(confidence)) for language detection")
        return nil
    }
    
    /// Common Japanese Kanji characters (expanded set)
    private let commonJapaneseKanji = Set([
        // Days of week
        "日", "月", "火", "水", "木", "金", "土",
        // Time related
        "年", "月", "日", "時", "分", "秒", "今", "昨", "明", "週", "曜",
        // Broadcasting related
        "放", "送", "番", "組", "局", "視", "聴", "録", "画", "映", "像",
        // News related
        "新", "聞", "話", "題", "報", "道", "記", "事", "者",
        // Other common kanji
        "東", "京", "大", "学", "会", "社", "人", "本", "中", "小", "上", "下",
        // Service/place related
        "出", "前", "館", "店", "場", "所", "駅",
        // General nouns
        "作", "品", "物", "件", "式", "法",
        // Actions/functions
        "使", "用", "利", "便", "機", "能",
        // Directions/scope
        "全", "部", "分", "内", "外", "北", "南",
        // Honorifics/people
        "先", "生", "様", "氏", "君"
    ])
    
    /// Analyze language context from multiple texts
    func analyzeLanguageContext(texts: [String]) -> String? {
        guard !texts.isEmpty else { return nil }
        
        Logger.shared.log(.debug, "\n[Context Analysis] Analyzing \(texts.count) texts")
        
        var languageVotes: [String: Int] = [:]
        var languageConfidences: [String: Double] = [:]
        
        // Analyze each text
        for (index, text) in texts.enumerated() {
            Logger.shared.log(.debug, "[Context Analysis] Text \(index + 1): '\(text)'")
            
            // Skip texts with only numbers/special characters
            let cleanedText = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(String.init).joined()
            if cleanedText.isEmpty {
                Logger.shared.log(.debug, "  → Skipping (numbers/special chars only)")
                continue
            }
            
            // Detect language for this text
            if let detectedLang = detectLanguage(for: text, targetLanguage: targetLanguage) {
                languageVotes[detectedLang, default: 0] += 1
                
                // Add confidence scoring based on text characteristics
                var confidence = 1.0
                
                // Higher confidence for texts with language-specific characters
                if detectedLang == "ja" && text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}]", options: .regularExpression) != nil {
                    confidence = 2.0  // Hiragana/Katakana = high confidence
                } else if detectedLang == "ko" && text.range(of: "[\u{ac00}-\u{d7af}]", options: .regularExpression) != nil {
                    confidence = 2.0  // Hangul = high confidence
                } else if detectedLang == "ja" && hasJapaneseKanji(in: text) {
                    confidence = 1.5  // Japanese kanji = medium-high confidence
                }
                
                languageConfidences[detectedLang, default: 0] += confidence
                Logger.shared.log(.debug, "  → Detected: \(detectedLang) (confidence: \(confidence))")
            }
        }
        
        // Determine dominant language based on votes and confidence
        if languageConfidences.isEmpty {
            Logger.shared.log(.debug, "[Context Analysis] No languages detected")
            return nil
        }
        
        // Sort by total confidence
        let sortedLanguages = languageConfidences.sorted { $0.value > $1.value }
        let dominantLanguage = sortedLanguages.first?.key
        
        Logger.shared.log(.debug, "[Context Analysis] Language votes: \(languageVotes)")
        Logger.shared.log(.debug, "[Context Analysis] Language confidences: \(languageConfidences)")
        Logger.shared.log(.debug, "[Context Analysis] Dominant language: \(dominantLanguage ?? "none")")
        
        return dominantLanguage
    }
    
    /// Check if text contains Japanese kanji
    private func hasJapaneseKanji(in text: String) -> Bool {
        var japaneseKanjiCount = 0
        var totalKanji = 0
        
        for char in text {
            let scalar = char.unicodeScalars.first?.value ?? 0
            if scalar >= 0x4E00 && scalar <= 0x9FAF {
                totalKanji += 1
                if commonJapaneseKanji.contains(String(char)) {
                    japaneseKanjiCount += 1
                }
            }
        }
        
        // If 30% or more kanji are common Japanese kanji, consider it Japanese
        return totalKanji > 0 && (Double(japaneseKanjiCount) / Double(totalKanji)) >= 0.3
    }
    
    /// Detect dominant language from multiple texts with Japanese priority
    func detectDominantLanguage(from texts: [String], targetLanguage: String? = nil) -> String? {
        // Use the new context analysis method
        return analyzeLanguageContext(texts: texts)
    }
    
    /// Record language detection for context awareness
    private func recordLanguageDetection(_ language: String) {
        recentLanguageDetections.append((language, Date()))
        
        // Keep only recent detections (last 10 seconds)
        let cutoff = Date().addingTimeInterval(-10)
        recentLanguageDetections = recentLanguageDetections.filter { $0.timestamp > cutoff }
        
        // Limit to last 20 detections
        if recentLanguageDetections.count > 20 {
            recentLanguageDetections = Array(recentLanguageDetections.suffix(20))
        }
    }
    
    // MARK: - Cache Management
    
    private func getCacheKey(text: String, source: String, target: String) -> String {
        return "\(source)_\(target)_\(text)"
    }
    
    private func addToCache(key: String, value: String) {
        translationCache[key] = value
        
        // Limit cache size
        if translationCache.count > maxCacheSize {
            // Remove oldest entries (simple FIFO)
            let toRemove = translationCache.count - maxCacheSize
            for key in translationCache.keys.prefix(toRemove) {
                translationCache.removeValue(forKey: key)
            }
        }
    }
    
    func clearCache() {
        translationCache.removeAll()
        Logger.shared.log(.info, "Translation cache cleared")
    }
    
    // MARK: - Statistics
    
    func getCacheHitRate() -> Double {
        // This would need to track hits/misses for accurate calculation
        return Double(translationCache.count) / Double(maxCacheSize)
    }
}

// MARK: - Translation Session Helper View

@available(iOS 18.0, *)
struct TranslationSessionProvider: View {
    let sourceLanguage: String  // Explicit source language
    let targetLanguage: String
    let onSessionReady: (TranslationSession?) -> Void
    
    @State private var hasProvidedSession = false
    
    private var configuration: TranslationSession.Configuration? {
        // Create explicit language pair configuration (NO auto-detect!)
        let source = Locale.Language(identifier: sourceLanguage)
        let target = Locale.Language(identifier: targetLanguage)
        return TranslationSession.Configuration(source: source, target: target)
    }
    
    var body: some View {
        Group {
            if let config = configuration {
                Color.clear
                    .frame(width: 0, height: 0)
                    .translationTask(config) { session in
                        if !hasProvidedSession {
                            hasProvidedSession = true
                            onSessionReady(session)
                            Logger.shared.log(.info, "Translation session created: \(sourceLanguage)→\(targetLanguage)")
                        }
                    }
            } else {
                EmptyView()
                    .onAppear {
                        onSessionReady(nil)
                        Logger.shared.log(.warning, "Failed to create configuration: \(sourceLanguage)→\(targetLanguage)")
                    }
            }
        }
    }
}