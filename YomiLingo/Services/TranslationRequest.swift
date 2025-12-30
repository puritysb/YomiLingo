//
//  TranslationRequest.swift
//  ViewLingo-Cam
//
//  Manages translation requests without storing sessions
//

import SwiftUI
import Translation

@available(iOS 18.0, *)
@MainActor
class TranslationRequest: ObservableObject {
    @Published var pendingRequests: [(id: UUID, text: String, source: String, target: String)] = []
    @Published var completedTranslations: [UUID: String] = [:]
    
    func requestTranslation(text: String, source: String, target: String) -> UUID {
        let id = UUID()
        pendingRequests.append((id, text, source, target))
        return id
    }
    
    func completeTranslation(id: UUID, translation: String) {
        completedTranslations[id] = translation
        pendingRequests.removeAll { $0.id == id }
    }
    
    func getTranslation(for id: UUID) -> String? {
        return completedTranslations[id]
    }
    
    func clearCompleted() {
        completedTranslations.removeAll()
    }
}

// TranslationExecutor moved to TranslationCoordinator.swift