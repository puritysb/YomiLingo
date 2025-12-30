//
//  ViewLingoCamApp.swift
//  ViewLingo-Cam
//
//  Clean and simple app entry point
//

import SwiftUI

@main
struct ViewLingoCamApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        Logger.shared.log(.info, "🚀 ViewLingo-Cam Starting...")
        Logger.shared.log(.info, "📱 iOS Version: \(UIDevice.current.systemVersion)")
        Logger.shared.log(.info, "🎯 App Version: 2.0.0")
    }
    
    var body: some Scene {
        WindowGroup {
            if #available(iOS 18.0, *) {
                RootView()
                    .environmentObject(appState)
                    .preferredColorScheme(.dark)
            } else {
                UnsupportedVersionView()
            }
        }
    }
}

// Simple view for unsupported iOS versions
struct UnsupportedVersionView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.yellow)
            
            Text("iOS 18 Required")
                .font(.title)
                .fontWeight(.bold)
            
            Text("ViewLingo Cam requires iOS 18.0 or later for optimal translation performance.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Text("Please update your device to use this app.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}