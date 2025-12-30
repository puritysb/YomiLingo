//
//  TranslationCoordinator.swift
//  ViewLingo-Cam
//
//  Coordinates translation requests without storing TranslationSession instances
//  Uses a request-based system to ensure sessions are only used within translationTask
//

import SwiftUI
import Translation
import NaturalLanguage

@available(iOS 18.0, *)
@MainActor
class TranslationCoordinator: ObservableObject {
    // MARK: - Published Properties
    
    @Published var pendingRequests: [TranslationRequest] = []
    @Published var isTranslating = false
    @Published var triggerProcessing = false
    @Published var installedLanguagePairs: Set<String> = []
    
    // MARK: - Private Properties
    
    private var translationCache: [String: String] = [:]
    private let maxCacheSize = 200
    private let languageRecognizer = NLLanguageRecognizer()
    weak var appState: AppState?
    
    // MARK: - Types
    
    struct TranslationRequest: Identifiable {
        let id = UUID()
        let texts: [String]
        let sourceLanguage: String
        let targetLanguage: String
        let completion: ([String: String]) -> Void
    }
    
    // MARK: - Initialization
    
    init() {
        Logger.shared.log(.info, "TranslationCoordinator initialized")
        // Check installed language packs on init
        Task {
            await checkInstalledLanguagePacks()
        }
    }
    
    // MARK: - Public Methods
    
    /// Request translation for texts
    func requestTranslation(
        texts: [String],
        from sourceLanguage: String,
        to targetLanguage: String,
        completion: @escaping ([String: String]) -> Void
    ) {
        // Validate: Don't translate same language to same language
        if sourceLanguage == targetLanguage {
            Logger.shared.log(.warning, "⚠️ Skipping invalid same-language translation: \(sourceLanguage)→\(targetLanguage)")
            completion([:])  // Return empty results
            return
        }
        
        // Check cache first
        var cachedResults: [String: String] = [:]
        var uncachedTexts: [String] = []
        
        for text in texts {
            let cacheKey = getCacheKey(text: text, source: sourceLanguage, target: targetLanguage)
            if let cached = translationCache[cacheKey] {
                cachedResults[text] = cached
            } else {
                uncachedTexts.append(text)
            }
        }
        
        // If all are cached, return immediately
        if uncachedTexts.isEmpty {
            completion(cachedResults)
            return
        }
        
        // Create request for uncached texts
        let request = TranslationRequest(
            texts: uncachedTexts,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            completion: { [weak self] results in
                // Cache new results
                for (text, translation) in results {
                    let cacheKey = self?.getCacheKey(text: text, source: sourceLanguage, target: targetLanguage) ?? ""
                    self?.addToCache(key: cacheKey, value: translation)
                }
                
                // Combine with cached results
                var finalResults = cachedResults
                for (text, translation) in results {
                    finalResults[text] = translation
                }
                
                completion(finalResults)
            }
        )
        
        pendingRequests.append(request)
        isTranslating = true
        triggerProcessing.toggle()  // Trigger the executor
    }
    
    /// Process the next pending request (called by TranslationExecutor)
    func getNextRequest() -> TranslationRequest? {
        guard !pendingRequests.isEmpty else {
            isTranslating = false
            return nil
        }
        return pendingRequests.removeFirst()
    }
    
    /// Mark a language pair as installed
    func markLanguagePairInstalled(source: String, target: String) {
        let pairKey = "\(source)→\(target)"
        installedLanguagePairs.insert(pairKey)
        Logger.shared.log(.info, "✅ Language pair marked as installed: \(pairKey)")
        
        // Save to UserDefaults for persistence
        UserDefaults.standard.set(Array(installedLanguagePairs), forKey: "InstalledLanguagePairs")
    }
    
    /// Check if a language pair is installed
    func isLanguagePairInstalled(source: String, target: String) -> Bool {
        let pairKey = "\(source)→\(target)"
        return installedLanguagePairs.contains(pairKey)
    }
    
    /// Check installed language packs
    func checkInstalledLanguagePacks() async {
        // Load from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: "InstalledLanguagePairs") as? [String] {
            installedLanguagePairs = Set(saved)
            Logger.shared.log(.info, "Loaded \(installedLanguagePairs.count) installed language pairs")
        }
        
        // We can't directly check Translation framework installation status
        // but we track successful installations through markLanguagePairInstalled
    }
    
    /// Detect language for texts
    func detectLanguages(for texts: [String]) -> [String: [String]] {
        var textsByLanguage: [String: [String]] = [:]
        
        for text in texts {
            let language = detectLanguage(for: text)
            if textsByLanguage[language] == nil {
                textsByLanguage[language] = []
            }
            textsByLanguage[language]?.append(text)
        }
        
        return textsByLanguage
    }
    
    // MARK: - Private Methods
    
    private func detectLanguage(for text: String) -> String {
        // Priority 1: Check for Korean characters (even if mixed with English)
        // This is important for mixed code/Korean content
        if text.range(of: "[\\uAC00-\\uD7AF]", options: .regularExpression) != nil {
            return "ko"
        }
        
        // Priority 2: Check for Japanese characters
        if text.range(of: "[\\u3040-\\u309F\\u30A0-\\u30FF]", options: .regularExpression) != nil {
            return "ja"
        }
        
        // Priority 3: Check for French characters
        if containsFrenchCharacters(text) {
            return "fr"
        }
        
        // Priority 4: Check for Chinese characters
        if text.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil {
            // Could be Chinese or Japanese kanji, use NaturalLanguage to distinguish
            languageRecognizer.processString(text)
            if let language = languageRecognizer.dominantLanguage?.rawValue {
                let langCode = String(language.prefix(2))
                if langCode == "zh" || langCode == "ja" {
                    return langCode == "zh" ? "zh" : "ja"
                }
            }
            return "zh"  // Default to Chinese for CJK ideographs
        }
        
        // Use NaturalLanguage for more complex detection
        languageRecognizer.processString(text)
        
        if let language = languageRecognizer.dominantLanguage?.rawValue {
            let langCode = String(language.prefix(2))
            if ["en", "ko", "ja", "fr"].contains(langCode) {
                return langCode
            }
        }
        
        // Default to English
        return "en"
    }
    
    private func containsFrenchCharacters(_ text: String) -> Bool {
        // French-specific characters and patterns
        let frenchPatterns = [
            "à", "â", "é", "è", "ê", "ë", "î", "ï", "ô", "ù", "û", "ç", "œ", "æ",
            "À", "Â", "É", "È", "Ê", "Ë", "Î", "Ï", "Ô", "Ù", "Û", "Ç", "Œ", "Æ"
        ]
        
        for pattern in frenchPatterns {
            if text.contains(pattern) {
                return true
            }
        }
        
        // Check for common French words
        let frenchWords = ["le", "la", "les", "de", "et", "un", "une", "pour", "avec", "dans", "sur"]
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines)
        for word in frenchWords {
            if words.contains(word) {
                return true
            }
        }
        
        return false
    }
    
    private func getCacheKey(text: String, source: String, target: String) -> String {
        return "\(source)_\(target)_\(text)"
    }
    
    private func addToCache(key: String, value: String) {
        translationCache[key] = value
        
        // Limit cache size
        if translationCache.count > maxCacheSize {
            let toRemove = translationCache.count - maxCacheSize
            for key in translationCache.keys.prefix(toRemove) {
                translationCache.removeValue(forKey: key)
            }
        }
    }
}

// MARK: - Translation Executor View

@available(iOS 18.0, *)
struct TranslationExecutor: View {
    @ObservedObject var coordinator: TranslationCoordinator
    @State private var currentRequest: TranslationCoordinator.TranslationRequest?
    @State private var isProcessing = false
    
    var body: some View {
        Group {
            if let request = currentRequest {
                TranslationTaskView(
                    request: request,
                    coordinator: coordinator,
                    onComplete: {
                        // Process next request
                        currentRequest = coordinator.getNextRequest()
                    }
                )
            }
        }
        .onReceive(coordinator.$pendingRequests) { requests in
            // Start processing if we have requests and not already processing
            if currentRequest == nil && !requests.isEmpty {
                currentRequest = coordinator.getNextRequest()
            }
        }
        .onReceive(coordinator.$triggerProcessing) { _ in
            // Additional trigger to ensure processing starts
            if currentRequest == nil && !coordinator.pendingRequests.isEmpty {
                currentRequest = coordinator.getNextRequest()
            }
        }
    }
}

// MARK: - Translation Task View

@available(iOS 18.0, *)
struct TranslationTaskView: View {
    let request: TranslationCoordinator.TranslationRequest
    @ObservedObject var coordinator: TranslationCoordinator
    let onComplete: () -> Void
    
    @State private var hasProcessed = false
    
    private var configuration: TranslationSession.Configuration? {
        let source = Locale.Language(identifier: request.sourceLanguage)
        let target = Locale.Language(identifier: request.targetLanguage)
        return TranslationSession.Configuration(source: source, target: target)
    }
    
    var body: some View {
        Group {
            if let config = configuration {
                Color.clear
                    .frame(width: 0, height: 0)
                    .translationTask(config) { session in
                        if !hasProcessed {
                            hasProcessed = true
                            Task {
                                await performTranslation(session: session)
                            }
                        }
                    }
            }
        }
    }
    
    private func performTranslation(session: TranslationSession) async {
        let pairKey = "\(request.sourceLanguage)→\(request.targetLanguage)"
        
        do {
            // Log start of translation
            Logger.shared.log(.info, "🔄 Starting translation for \(request.texts.count) texts (\(pairKey))")
            
            // Prepare session if not already installed
            if !coordinator.isLanguagePairInstalled(source: request.sourceLanguage, target: request.targetLanguage) {
                Logger.shared.log(.info, "📥 Preparing language pack for \(pairKey)...")
                try await session.prepareTranslation()
                
                // Mark as installed after successful preparation
                await MainActor.run {
                    coordinator.markLanguagePairInstalled(source: request.sourceLanguage, target: request.targetLanguage)
                }
                Logger.shared.log(.info, "✅ Language pack installed and marked: \(pairKey)")
            }
            
            // Create translation requests
            let translationRequests = request.texts.map { 
                TranslationSession.Request(sourceText: $0) 
            }
            
            // Perform translation
            Logger.shared.log(.info, "📝 Translating \(translationRequests.count) texts...")
            let responses = try await session.translations(from: translationRequests)
            
            // Build results
            var results: [String: String] = [:]
            for (index, response) in responses.enumerated() {
                if index < request.texts.count {
                    results[request.texts[index]] = response.targetText
                    Logger.shared.log(.debug, "✅ Translated: '\(String(request.texts[index].prefix(30)))...' → '\(String(response.targetText.prefix(30)))...'")
                }
            }
            Logger.shared.log(.info, "✅ Translation completed: \(results.count) texts translated")
            
            // Call completion on main thread
            await MainActor.run {
                request.completion(results)
                onComplete()
            }
            
        } catch {
            Logger.shared.log(.error, "❌ Translation failed for \(pairKey): \(error.localizedDescription)")
            await MainActor.run {
                request.completion([:])
                onComplete()
            }
        }
    }
}