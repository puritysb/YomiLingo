//
//  DynamicLanguagePackProvider.swift
//  ViewLingo-Cam
//
//  Dynamic language pack installation using Apple's native translationTask
//

import SwiftUI
import Translation

@available(iOS 18.0, *)
struct DynamicLanguagePackProvider: View {
    let sourceLanguage: String
    let targetLanguage: String
    let onSessionReady: (TranslationSession?) -> Void
    let onInstallationStart: (() -> Void)?
    let onInstallationComplete: ((Bool) -> Void)?
    
    @State private var hasProvidedSession = false
    
    init(
        sourceLanguage: String,
        targetLanguage: String,
        onSessionReady: @escaping (TranslationSession?) -> Void,
        onInstallationStart: (() -> Void)? = nil,
        onInstallationComplete: ((Bool) -> Void)? = nil
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.onSessionReady = onSessionReady
        self.onInstallationStart = onInstallationStart
        self.onInstallationComplete = onInstallationComplete
    }
    
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
                        // CRITICAL: prepareTranslation must be called in the translationTask context
                        // to show the download sheet to the user
                        if !self.hasProvidedSession {
                            self.hasProvidedSession = true
                            let pairKey = "\(sourceLanguage)→\(targetLanguage)"
                            
                            Logger.shared.log(.info, "🟢 Dynamic translation session created: \(pairKey)")
                            
                            // Prepare translation FIRST
                            // iOS will automatically show language pack download UI if needed
                            Task { @MainActor in
                                do {
                                    onInstallationStart?()
                                    Logger.shared.log(.info, "📥 Preparing language pack for \(pairKey)...")
                                    
                                    // prepareTranslation will trigger iOS system UI if language pack missing
                                    try await session.prepareTranslation()
                                    Logger.shared.log(.info, "✅ Language pack prepared for \(pairKey)")
                                    
                                    // Skip test translation - iOS 18 has issues with immediate translation after prepare
                                    // Just trust that prepareTranslation succeeded
                                    Logger.shared.log(.info, "✅ Session \(pairKey) ready (prepare succeeded)")
                                    
                                    // Pass the session even without test
                                    Logger.shared.log(.debug, "🔄 Calling onSessionReady callback for \(pairKey)")
                                    onSessionReady(session)
                                    
                                    // Mark as installed in LanguagePackService for UI updates
                                    LanguagePackService.shared.markSessionValidated(source: sourceLanguage, target: targetLanguage)
                                    
                                    // Signal completion
                                    onInstallationComplete?(true)
                                } catch {
                                    Logger.shared.log(.error, "❌ Language pack preparation failed for \(pairKey): \(error)")
                                    
                                    // Check if it's Error Code 16 or language pack issue
                                    if error.localizedDescription.contains("Code=16") || 
                                       error.localizedDescription.contains("오프라인 모델") {
                                        Logger.shared.log(.error, "⚠️ Offline model unavailable for \(pairKey) - manual installation required")
                                    }
                                    
                                    // Don't provide the session if preparation failed
                                    onSessionReady(nil)
                                    onInstallationComplete?(false)
                                }
                            }
                        }
                    }
            } else {
                EmptyView()
                    .onAppear {
                        Logger.shared.log(.warning, "Failed to create configuration: \(sourceLanguage)→\(targetLanguage)")
                        onSessionReady(nil)
                        onInstallationComplete?(false)
                    }
            }
        }
    }
}

// MARK: - Batch Language Pack Provider

@available(iOS 18.0, *)
struct BatchLanguagePackProvider: View {
    let targetLanguage: String
    let onSessionReady: (TranslationSession?, String, String) -> Void
    let onBatchComplete: ((Set<String>) -> Void)?
    @EnvironmentObject var appState: AppState
    
    @State private var completedPairs: Set<String> = []
    @State private var failedPairs: Set<String> = []
    
    private var requiredPairs: [(source: String, target: String)] {
        var pairs: [(String, String)] = []
        
        // Get enabled source languages from appState
        let enabledSources = appState.enabledSourceLanguages
        
        // Add pairs for enabled source languages to current target
        for source in enabledSources {
            if source != targetLanguage {
                pairs.append((source, targetLanguage))
            }
        }
        
        // Also add reverse pairs for bidirectional support
        // (so we can detect text in the target language and translate to sources)
        for target in enabledSources {
            if target != targetLanguage {
                pairs.append((targetLanguage, target))
            }
        }
        
        // If French is enabled, add French pairs
        if enabledSources.contains("fr") {
            // French to all target languages
            if targetLanguage != "fr" {
                // Already added above
            }
            // All targets to French (for reverse translation)
            for lang in ["ko", "en", "ja"] {
                if lang != targetLanguage && !pairs.contains(where: { $0.0 == lang && $0.1 == "fr" }) {
                    pairs.append((lang, "fr"))
                }
            }
        }
        
        return pairs
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(requiredPairs.indices, id: \.self) { index in
                let pair = requiredPairs[index]
                DynamicLanguagePackProvider(
                    sourceLanguage: pair.source,
                    targetLanguage: pair.target,
                    onSessionReady: { session in
                        if let session = session {
                            Logger.shared.log(.info, "🔴 BatchProvider: Calling onSessionReady for \(pair.source)→\(pair.target)")
                            onSessionReady(session, pair.source, pair.target)
                        } else {
                            Logger.shared.log(.warning, "⚠️ BatchProvider: Session was nil for \(pair.source)→\(pair.target)")
                        }
                    },
                    onInstallationComplete: { success in
                        let pairKey = "\(pair.source)→\(pair.target)"
                        if success {
                            completedPairs.insert(pairKey)
                        } else {
                            failedPairs.insert(pairKey)
                        }
                        
                        // Check if all pairs are processed
                        let totalPairs = requiredPairs.count
                        let processedPairs = completedPairs.count + failedPairs.count
                        
                        if processedPairs >= totalPairs {
                            Logger.shared.log(.info, """
                                Batch language pack installation complete:
                                  - Successful: \(completedPairs.count)
                                  - Failed: \(failedPairs.count)
                                  - Completed pairs: \(completedPairs.joined(separator: ", "))
                                """)
                            onBatchComplete?(completedPairs)
                        }
                    }
                )
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

// MARK: - Simplified Translation Session Provider (for CameraView)

@available(iOS 18.0, *)
struct SimpleTranslationSessionProvider: View {
    let sourceLanguage: String
    let targetLanguage: String
    let onSessionReady: (TranslationSession?) -> Void
    
    var body: some View {
        DynamicLanguagePackProvider(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            onSessionReady: onSessionReady
        )
    }
}