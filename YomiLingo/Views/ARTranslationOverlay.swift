//
//  ARTranslationOverlay.swift
//  ViewLingo-Cam
//
//  AR overlay for displaying translations over original text
//

import SwiftUI

struct ARTranslationOverlay: View {
    let trackedTexts: [TrackedText]
    let useHybridTracking: Bool
    let hybridPositions: [(id: UUID, text: String, translation: String?, box: CGRect)]
    
    init(trackedTexts: [TrackedText], 
         useHybridTracking: Bool = false,
         hybridPositions: [(id: UUID, text: String, translation: String?, box: CGRect)] = []) {
        self.trackedTexts = trackedTexts
        self.useHybridTracking = useHybridTracking
        self.hybridPositions = hybridPositions
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if useHybridTracking {
                    // Use hybrid tracking positions (no animation)
                    ForEach(hybridPositions, id: \.id) { item in
                        if let translation = item.translation {
                            TranslationBubble(
                                id: item.id,
                                originalText: item.text,
                                translatedText: translation,
                                boundingBox: item.box,  // Direct position, no smoothing
                                confidence: 1.0,
                                screenSize: geometry.size
                            )
                            // No animation - direct position updates
                        }
                    }
                } else {
                    // Legacy tracking mode (for compatibility)
                    ForEach(trackedTexts.filter { $0.translation != nil && $0.isOnScreen }) { tracked in
                        TranslationBubble(
                            id: tracked.id,
                            originalText: tracked.text,
                            translatedText: tracked.translation ?? "",
                            boundingBox: tracked.smoothedBox,
                            confidence: tracked.confidence,
                            screenSize: geometry.size
                        )
                        // Removed animation for faster response
                    }
                }
            }
        }
    }
}

// MARK: - Translation Bubble

struct TranslationBubble: View {
    let id: UUID  // For stable identity
    let originalText: String
    let translatedText: String
    let boundingBox: CGRect
    let confidence: Float
    let screenSize: CGSize
    
    @State private var showOriginal = false
    
    private var position: CGPoint {
        // Convert normalized coordinates to screen coordinates
        var x = boundingBox.midX * screenSize.width
        var y = (1 - boundingBox.midY) * screenSize.height  // Flip Y coordinate
        
        // Keep bubbles within screen bounds
        let bubbleHalfWidth = bubbleWidth / 2
        let _ : CGFloat = 60  // Approximate height (unused but kept for reference)
        
        // Horizontal bounds
        x = max(bubbleHalfWidth + 20, x)  // 20pt margin from edges
        x = min(screenSize.width - bubbleHalfWidth - 20, x)
        
        // Vertical bounds - avoid top/bottom UI areas
        y = max(120, y)  // Stay below top bar (increased from status bar)
        y = min(screenSize.height - 140, y)  // Stay above capture button
        
        return CGPoint(x: x, y: y)
    }
    
    private var bubbleWidth: CGFloat {
        min(boundingBox.width * screenSize.width * 1.2, screenSize.width - 40)
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // Translation bubble
            Text(showOriginal ? originalText : translatedText)
                .font(.system(size: fontSize))
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderColor, lineWidth: 1)
                )
            
            // Confidence indicator
            if confidence < 0.9 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("\(Int(confidence * 100))%")
                        .font(.caption2)
                }
                .foregroundColor(.yellow)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
            }
        }
        .position(position)
        .zIndex(Double(100 - Int(position.y / 10)))  // Layer based on vertical position
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showOriginal.toggle()
            }
        }
    }
    
    private var fontSize: CGFloat {
        // Adjust font size based on text length
        let baseSize: CGFloat = 14  // Reduced base size for better fit
        if translatedText.count > 50 {
            return baseSize * 0.85
        } else if translatedText.count > 100 {
            return baseSize * 0.7
        }
        return baseSize
    }
    
    private var backgroundColor: Color {
        // More visible colors
        if confidence > 0.8 {
            return Color.blue
        } else if confidence > 0.5 {
            return Color.indigo
        } else {
            return Color.purple
        }
    }
    
    private var borderColor: Color {
        confidence > 0.9 ? Color.white.opacity(0.3) : Color.yellow.opacity(0.5)
    }
}

// MARK: - Debug Overlay (for development)

struct DebugOverlay: View {
    let recognizedTexts: [OCRService.RecognizedText]
    let screenSize: CGSize
    
    var body: some View {
        ZStack {
            ForEach(Array(recognizedTexts.enumerated()), id: \.offset) { index, text in
                Rectangle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(
                        width: text.boundingBox.width * screenSize.width,
                        height: text.boundingBox.height * screenSize.height
                    )
                    .position(
                        x: text.boundingBox.midX * screenSize.width,
                        y: (1 - text.boundingBox.midY) * screenSize.height
                    )
                    .overlay(
                        Text("\(index)")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(2)
                            .background(Color.black.opacity(0.7))
                            .position(
                                x: text.boundingBox.minX * screenSize.width + 15,
                                y: (1 - text.boundingBox.maxY) * screenSize.height + 15
                            )
                    )
            }
        }
    }
}