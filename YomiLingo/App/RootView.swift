//
//  RootView.swift
//  ViewLingo-Cam
//
//  Root view that directly shows camera (onboarding removed)
//

import SwiftUI

@available(iOS 18.0, *)
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDebugInfo = false
    
    var body: some View {
        ZStack {
            // Main camera view - no onboarding required
            CameraView()
                .transition(.opacity)
        }
        .sheet(isPresented: $showDebugInfo) {
            DebugView()
        }
        .onAppear {
            Logger.shared.log(.info, "RootView appeared - direct camera access (onboarding removed)")
        }
    }
}