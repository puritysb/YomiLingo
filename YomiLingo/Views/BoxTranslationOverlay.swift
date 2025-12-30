//
//  BoxTranslationOverlay.swift
//  ViewLingo-Cam
//
//  AR overlay that precisely covers original text boxes with translations
//

import SwiftUI
import UIKit

/// Displays translations directly over original text areas
struct BoxTranslationOverlay: View {
    let trackedTexts: [TrackedText]
    @EnvironmentObject var appState: AppState
    
    // Computed property to simplify complex expression
    private var filteredTrackedTexts: [TrackedText] {
        return trackedTexts.filter { tracked in
            // Show placeholders immediately for detected texts
            // Show translations when available
            return tracked.isDisplayable && tracked.isOnScreen
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(filteredTrackedTexts) { tracked in
                    overlayView(for: tracked, screenSize: geometry.size)
                }
            }
        }
    }
    
    @ViewBuilder
    private func overlayView(for tracked: TrackedText, screenSize: CGSize) -> some View {
        if tracked.detectionState == .detected || tracked.detectionState == .translating {
            placeholderView(for: tracked, screenSize: screenSize)
        } else if tracked.translation != nil || tracked.bestTranslation != nil {
            translationView(for: tracked, screenSize: screenSize)
        }
    }
    
    @ViewBuilder
    private func placeholderView(for tracked: TrackedText, screenSize: CGSize) -> some View {
        PlaceholderBox(
            originalText: tracked.bestText,
            boundingBox: tracked.smoothedBox,
            confidence: tracked.bestConfidence,
            screenSize: screenSize,
            detectionState: tracked.detectionState,
            arMode: appState.arMode
        )
        .animation(
            .easeInOut(duration: 0.2),
            value: tracked.smoothedBox
        )
    }
    
    @ViewBuilder
    private func translationView(for tracked: TrackedText, screenSize: CGSize) -> some View {
        let translatedText = tracked.translation ?? tracked.bestTranslation ?? ""
        let animationStyle = appState.arMode == .standard
            ? Animation.interactiveSpring(response: 0.25, dampingFraction: 0.85)
            : Animation.interactiveSpring(response: 0.3, dampingFraction: 0.8)
        
        BoxTranslation(
            originalText: tracked.bestText,
            translatedText: translatedText,
            boundingBox: tracked.smoothedBox,
            confidence: tracked.bestConfidence,
            screenSize: screenSize,
            qualityScore: tracked.qualityScore,
            suspicionLevel: tracked.suspicionLevel,
            arMode: appState.arMode,
            isVerticalText: tracked.isVerticalText,
            sourceLanguage: tracked.sourceLanguage,
            isCapturedImage: false  // Live mode, no Y-axis adjustment needed
        )
        .animation(animationStyle, value: tracked.smoothedBox)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95)),
            removal: .opacity
        ))
    }
}

// MARK: - Placeholder Box for Loading State

struct PlaceholderBox: View {
    let originalText: String
    let boundingBox: CGRect
    let confidence: Float
    let screenSize: CGSize
    let detectionState: DetectionState
    let arMode: ARMode
    let isCapturedImage: Bool = false  // Whether this is from a captured image (not used in placeholder)
    
    @State private var pulseAnimation = false
    
    // Convert normalized coordinates to screen coordinates
    private var screenBox: CGRect {
        // Calculate base position
        var box = CGRect(
            x: boundingBox.origin.x * screenSize.width,
            y: (1 - boundingBox.maxY) * screenSize.height,  // Flip Y and use maxY for top
            width: boundingBox.width * screenSize.width,
            height: boundingBox.height * screenSize.height
        )
        
        // Apply fine-tuning for captured images
        if isCapturedImage {
            // Dynamic offset based on box height (larger boxes need more adjustment)
            let heightRatio = boundingBox.height
            let yOffset = -screenSize.height * heightRatio * 0.03  // 3% of box height upward
            box.origin.y += yOffset
        }
        
        return box
    }
    
    var body: some View {
        ZStack {
            // Light background with animated opacity
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    Color.gray.opacity(detectionState == .translating ? 0.4 : 0.3)
                )
                .overlay(
                    // Animated border for loading state
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(pulseAnimation ? 0.6 : 0.3),
                                    Color.blue.opacity(pulseAnimation ? 0.3 : 0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: detectionState == .translating ? 2 : 1
                        )
                )
                .frame(width: screenBox.width, height: screenBox.height)
                .position(x: screenBox.midX, y: screenBox.midY)
                .scaleEffect(pulseAnimation ? 1.02 : 1.0)
            
            // Loading indicator or original text
            Group {
                if detectionState == .translating {
                    // Show progress indicator
                    HStack(spacing: 4) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                        Text("Translating...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                } else {
                    // Show original text in light gray
                    Text(originalText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(
                width: screenBox.width * 0.9,
                height: screenBox.height * 0.9,
                alignment: .center
            )
            .position(x: screenBox.midX, y: screenBox.midY)
        }
        .onAppear {
            // Start pulsing animation for loading state
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                pulseAnimation = true
            }
        }
    }
}

// MARK: - Individual Box Translation

struct BoxTranslation: View {
    let originalText: String
    let translatedText: String
    let boundingBox: CGRect
    let confidence: Float
    let screenSize: CGSize
    let qualityScore: Float  // Add quality score for adaptive styling
    let suspicionLevel: Float  // Suspicion level for gradual fade-out (0.0=confident, 1.0=suspicious)
    let arMode: ARMode  // AR mode for enhanced effects
    let isVerticalText: Bool  // Indicates if this is vertical text
    let sourceLanguage: String?  // Source language for layout decisions
    let isCapturedImage: Bool  // Whether this is from a captured image (needs Y-axis adjustment)
    
    @State private var calculatedFontSize: CGFloat = 14
    @State private var showOriginal = false
    @State private var opacity: Double = 1.0
    @State private var appearAnimation = false
    @State private var expandedWidth: CGFloat = 1.0  // Dynamic width multiplier
    
    /// Clean text for display by removing visual noise
    private func cleanForDisplay(_ text: String) -> String {
        // Remove broken/replacement characters
        var cleaned = text.replacingOccurrences(of: "￿", with: "")
        
        // Only remove consecutive bullet characters, preserve currency symbols
        cleaned = cleaned.replacingOccurrences(of: "[•·]{2,}", with: "", options: .regularExpression)
        
        // Remove standalone bullets at start/end
        cleaned = cleaned.replacingOccurrences(of: "^[•·]+|[•·]+$", with: "", options: .regularExpression)
        
        // Collapse multiple spaces
        cleaned = cleaned.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // Convert normalized coordinates to screen coordinates
    private var screenBox: CGRect {
        // Calculate base position
        var box = CGRect(
            x: boundingBox.origin.x * screenSize.width,
            y: (1 - boundingBox.maxY) * screenSize.height,  // Flip Y and use maxY for top
            width: boundingBox.width * screenSize.width,
            height: boundingBox.height * screenSize.height
        )
        
        // Apply fine-tuning for captured images
        if isCapturedImage {
            // Dynamic offset based on box height (larger boxes need more adjustment)
            let heightRatio = boundingBox.height
            let yOffset = -screenSize.height * heightRatio * 0.03  // 3% of box height upward
            box.origin.y += yOffset
        }
        
        return box
    }
    
    var body: some View {
        ZStack {
            // Semi-transparent background to cover original text
            Group {
                if arMode == .standard {
                    // Standard mode: Quality-based visual feedback for 2D tracking
                    ZStack {
                        // Background layer with adaptive opacity
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                Color.black.opacity(qualityScore > 0.7 ? 0.65 : 0.55)  // Adaptive opacity
                            )
                            .blur(radius: 0.5)  // Subtle blur for depth
                        
                        // Quality indicator border
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(borderColorByQuality, lineWidth: qualityScore > 0.6 ? 2 : 1.5)
                            .animation(.easeInOut(duration: 0.3), value: qualityScore)
                        
                        // Inner glow for high quality
                        if qualityScore > 0.8 {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.2),
                                            Color.clear
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 1, y: 2)
                    .scaleEffect(showOriginal ? 0.96 : 1.0)
                    .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: showOriginal)
                } else if arMode == .arkit {
                    // ARKit mode: 3D-like appearance
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(0.85),
                                    Color.blue.opacity(0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 6, x: 3, y: 3)
                        .rotation3DEffect(
                            .degrees(showOriginal ? 5 : 0),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.5
                        )
                        .animation(.easeInOut(duration: 0.2), value: showOriginal)
                }
            }
            .frame(width: screenBox.width * expandedWidth, height: screenBox.height)
            .position(
                x: screenBox.midX,
                y: screenBox.midY
            )
            
            // Translated text - cleaned for display
            Group {
                if arMode == .standard {
                    // Standard mode: Optimized text rendering with quality-aware styling
                    let shouldUseVerticalLayout = determineVerticalLayout()
                    
                    if shouldUseVerticalLayout && isJapaneseText(showOriginal ? originalText : translatedText) {
                        // Real vertical text layout for Japanese
                        VerticalJapaneseText(
                            text: cleanForDisplay(showOriginal ? originalText : translatedText),
                            fontSize: calculatedFontSize,
                            fontWeight: textWeightForStandard,
                            textColor: textColorForStandard,
                            frame: CGSize(
                                width: (screenBox.width * expandedWidth) * 0.95,
                                height: screenBox.height * 0.95
                            )
                        )
                        .opacity(showOriginal ? 0.9 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: showOriginal)
                    } else {
                        // Regular horizontal or rotated text
                        let isVerticalBox = screenBox.height > screenBox.width * 1.5
                        let shouldRotate = shouldRotateVerticalBox(isVerticalBox, translatedText)
                        
                        // For rotated text, swap dimensions
                        let effectiveWidth = shouldRotate ? screenBox.height * 0.95 : (screenBox.width * expandedWidth) * 0.95
                        let effectiveHeight = shouldRotate ? (screenBox.width * expandedWidth) * 0.95 : screenBox.height * 0.95
                        
                        Text(cleanForDisplay(showOriginal ? originalText : translatedText))
                            .font(.system(size: calculatedFontSize, weight: textWeightForStandard))
                            .foregroundColor(textColorForStandard)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
                            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 0)  // Double shadow for better readability
                            .multilineTextAlignment(.center)
                            .lineLimit(1)  // FORCE single line to prevent text clipping
                            .truncationMode(.tail)  // Show ... if text is too long
                            .minimumScaleFactor(0.5)  // Allow more aggressive scaling if needed
                            .frame(
                                width: effectiveWidth,  // Use swapped dimensions for rotated text
                                height: effectiveHeight,
                                alignment: .center
                            )
                            .rotationEffect(shouldRotate ? .degrees(-90) : .degrees(0))  // Rotate Korean/English vertical boxes
                            .clipped()  // Safety net to prevent any overflow
                            .opacity(showOriginal ? 0.9 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: showOriginal)
                    }
                } else {
                    // ARKit mode: 3D-optimized text rendering
                    let shouldUseVerticalLayout = determineVerticalLayout()
                    
                    if shouldUseVerticalLayout && isJapaneseText(showOriginal ? originalText : translatedText) {
                        // Real vertical text layout for Japanese in ARKit
                        VerticalJapaneseText(
                            text: cleanForDisplay(showOriginal ? originalText : translatedText),
                            fontSize: calculatedFontSize,
                            fontWeight: .bold,
                            textColor: .white,
                            frame: CGSize(
                                width: (screenBox.width * expandedWidth) * 0.95,
                                height: screenBox.height * 0.95
                            )
                        )
                    } else {
                        let isVerticalBox = screenBox.height > screenBox.width * 1.5
                        let shouldRotate = shouldRotateVerticalBox(isVerticalBox, translatedText)
                        
                        // For rotated text, swap dimensions
                        let effectiveWidth = shouldRotate ? screenBox.height * 0.95 : (screenBox.width * expandedWidth) * 0.95
                        let effectiveHeight = shouldRotate ? (screenBox.width * expandedWidth) * 0.95 : screenBox.height * 0.95
                        
                        Text(cleanForDisplay(showOriginal ? originalText : translatedText))
                            .font(.system(size: calculatedFontSize, weight: .bold))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 1, x: 1, y: 1)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)  // FORCE single line to prevent text clipping
                            .truncationMode(.tail)  // Show ... if text is too long
                            .minimumScaleFactor(0.5)  // Allow more aggressive scaling if needed
                            .frame(
                                width: effectiveWidth,  // Use swapped dimensions for rotated text
                                height: effectiveHeight,
                                alignment: .center
                            )
                            .rotationEffect(shouldRotate ? .degrees(-90) : .degrees(0))  // Rotate Korean/English vertical boxes
                            .clipped()  // Safety net to prevent any overflow
                    }
                }
            }
            .position(
                x: screenBox.midX,
                y: screenBox.midY
            )
            .onAppear {
                calculateOptimalFontSize()
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showOriginal.toggle()
                }
            }
            
            // Debug: Show box outline in development
            #if DEBUG
            if ProcessInfo.processInfo.environment["SHOW_BOX_OUTLINE"] == "1" {
                Rectangle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
                    .frame(width: screenBox.width, height: screenBox.height)
                    .position(x: screenBox.midX, y: screenBox.midY)
            }
            #endif
        }
        .opacity(opacity * Double(max(0.2, 1.0 - suspicionLevel * 0.8)))
        .animation(.easeInOut(duration: 0.5), value: suspicionLevel) // Smooth fade animation
        .onAppear {
            // Fade in animation
            withAnimation(.easeIn(duration: 0.2)) {
                appearAnimation = true
                opacity = 1.0
            }
        }
        .onChange(of: suspicionLevel) { oldLevel, newLevel in
            // Log significant suspicion changes for debugging
            if abs(newLevel - oldLevel) > 0.3 {
                Logger.shared.log(.debug, "Text suspicion changed: \(String(format: "%.2f", oldLevel)) → \(String(format: "%.2f", newLevel)) for '\(originalText.prefix(20))...'")
            }
            
            // Instant restoration when confidence is regained
            if newLevel == 0.0 && oldLevel > 0.0 {
                withAnimation(.easeIn(duration: 0.2)) {
                    opacity = 1.0
                }
                Logger.shared.log(.debug, "Text confidence restored - suspicion: \(oldLevel) → \(newLevel)")
            }
        }
        .onChange(of: boundingBox) { oldBox, newBox in
            
            // CRITICAL: Recalculate font size when box size changes
            // Check if box size actually changed (not just position)
            let oldSize = CGSize(width: oldBox.width, height: oldBox.height)
            let newSize = CGSize(width: newBox.width, height: newBox.height)
            
            // Only recalculate if size changed significantly (> 5% change)
            let widthChange = abs(newSize.width - oldSize.width) / oldSize.width
            let heightChange = abs(newSize.height - oldSize.height) / oldSize.height
            
            if widthChange > 0.05 || heightChange > 0.05 {
                // Box size changed significantly - recalculate font size
                calculateOptimalFontSize()
            }
        }
    }
    
    private func isBoxMostlyOnScreen(_ box: CGRect) -> Bool {
        // Check if at least 70% of the box is on screen
        let screenBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let intersection = screenBounds.intersection(box)
        
        if intersection.isNull { return false }
        
        let intersectionArea = intersection.width * intersection.height
        let boxArea = box.width * box.height
        
        return boxArea > 0 ? (intersectionArea / boxArea) > 0.7 : false
    }
    
    // MARK: - Font Size Calculation
    
    private func calculateOptimalFontSize() {
        // Use cleaned text for font size calculation
        let cleanedText = cleanForDisplay(translatedText)
        
        // Use almost full box size for font calculation
        let sizeMultiplier: CGFloat = 0.98  // Use 98% of box size
        var boxSize = CGSize(width: screenBox.width * sizeMultiplier, height: screenBox.height * sizeMultiplier)
        
        // Dynamic font size based on box dimensions - using direct box size approach
        // (Area ratio calculation removed as we now use direct box height scaling)
        
        // Check if this is a vertical box (height > width * 1.5)
        let isVerticalBox = screenBox.height > screenBox.width * 1.5
        let willRotate = isVerticalBox && !isJapaneseText(translatedText)  // Check if text will be rotated
        
        // For rotated text, use the longer dimension (height) as the base
        // Since text will be rotated 90 degrees, the height becomes the effective width
        // We need a larger multiplier to properly fill the space
        let baseFontSize = willRotate 
            ? screenBox.width * 0.7   // Use box width (which becomes height after rotation) with larger multiplier
            : (isVerticalBox ? screenBox.width * 0.65 : screenBox.height * 0.65)  // Standard calculation
        
        // Improved min/max based on box size - more responsive to small boxes
        let absoluteMinSize: CGFloat = 4  // Reduced from 8pt for very small boxes
        let relativeMinSize = baseFontSize * 0.4  // Reduced from 0.5 for better small box response
        let minSize: CGFloat = max(absoluteMinSize, relativeMinSize)
        let maxSize: CGFloat = baseFontSize * 1.5  // Maximum 150% of base size
        
        // Get optimal size using binary search
        // For vertical boxes that will be rotated, swap dimensions
        let effectiveBoxSize = willRotate 
            ? CGSize(width: boxSize.height, height: boxSize.width)  // Swap dimensions for rotated text
            : boxSize
        
        var fontSize = FontSizeCalculator.calculateOptimalFontSize(
            for: cleanedText,
            in: effectiveBoxSize,
            minSize: minSize,
            maxSize: maxSize
        )
        
        // Check if text needs more width (for short texts or narrow boxes)
        // Skip this logic for rotated text as it doesn't help
        let textLength = cleanedText.count
        if !willRotate {
            if textLength < 30 && fontSize < baseFontSize * 0.8 {
                // Short text but small font - box might be too narrow
                // Try expanding width up to 1.3x
                let expandFactors: [CGFloat] = [1.1, 1.2, 1.3]
                for factor in expandFactors {
                    let expandedSize = CGSize(width: boxSize.width * factor, height: boxSize.height)
                    let newFontSize = FontSizeCalculator.calculateOptimalFontSize(
                        for: cleanedText,
                        in: expandedSize,
                        minSize: minSize,
                        maxSize: maxSize
                    )
                    
                    // If we can get significantly larger font, use expanded width
                    if newFontSize > fontSize * 1.3 {
                        expandedWidth = factor
                        boxSize = expandedSize
                        fontSize = newFontSize
                        break
                    }
                }
            } else if textLength > 50 && screenBox.width < screenSize.width * 0.15 {
                // Long text in narrow box - expand width
                expandedWidth = min(1.5, 1.0 + (CGFloat(textLength) / 100.0))
                boxSize = CGSize(width: boxSize.width * expandedWidth, height: boxSize.height)
                fontSize = FontSizeCalculator.calculateOptimalFontSize(
                    for: cleanedText,
                    in: boxSize,
                    minSize: minSize,
                    maxSize: maxSize
                )
            } else {
                expandedWidth = 1.0  // No expansion needed
            }
        } else {
            expandedWidth = 1.0  // No expansion for rotated text
        }
        
        // Simple adjustments based on text characteristics
        // For small boxes, prioritize fitting over enhancement adjustments
        let boxArea = screenBox.width * screenBox.height
        let screenArea = screenSize.width * screenSize.height
        let boxSizeRatio = boxArea / screenArea
        let isSmallBox = boxSizeRatio < 0.02  // Less than 2% of screen area
        
        if !isSmallBox {
            // Only apply enhancement adjustments for normal/large boxes
            // Quality-based adjustments (minimal)
            if qualityScore > 0.8 {
                fontSize *= 1.02  // Slight boost for high quality
            } else if qualityScore < 0.5 {
                fontSize *= 0.98  // Slight reduction for low quality
            }
            
            // Text length adjustments (minimal)
            if cleanedText.count < 5 && expandedWidth == 1.0 {
                fontSize *= 1.05  // Very short text gets slight boost
            } else if cleanedText.count > 80 {
                fontSize *= 0.95  // Very long text gets slight reduction
            }
            
            // Language-specific adjustments
            if hasComplexCharacters(translatedText) {
                fontSize *= 1.1  // CJK characters need slightly more space
            }
        } else {
            // For small boxes, focus on fitting - only apply reductions
            if cleanedText.count > 80 {
                fontSize *= 0.92  // More aggressive reduction for long text in small boxes
            }
        }
        
        // Final bounds check with mode-specific limits
        fontSize = max(minSize, min(fontSize, maxSize))
        
        calculatedFontSize = fontSize
    }
    
    private func hasComplexCharacters(_ text: String) -> Bool {
        // Check for CJK characters
        let cjkRegex = try? NSRegularExpression(
            pattern: "[\\u{4E00}-\\u{9FFF}\\u{3040}-\\u{309F}\\u{30A0}-\\u{30FF}\\u{AC00}-\\u{D7AF}]"
        )
        let range = NSRange(location: 0, length: text.utf16.count)
        return cjkRegex?.firstMatch(in: text, range: range) != nil
    }
    
    private func isJapaneseText(_ text: String) -> Bool {
        // Check if text contains Japanese characters (Hiragana, Katakana, or Kanji)
        return text.range(of: "[\\u{3040}-\\u{309F}\\u{30A0}-\\u{30FF}\\u{4E00}-\\u{9FAF}]", options: .regularExpression) != nil
    }
    
    private func isKoreanText(_ text: String) -> Bool {
        // Check if text contains Korean characters (Hangul)
        return text.range(of: "[\\u{AC00}-\\u{D7AF}\\u{1100}-\\u{11FF}\\u{3130}-\\u{318F}]", options: .regularExpression) != nil
    }
    
    private func isEnglishOrLatinText(_ text: String) -> Bool {
        // Check if text is primarily English/Latin characters
        // Remove spaces and punctuation for checking
        let cleanedText = text.replacingOccurrences(of: "[\\s\\p{P}]", with: "", options: .regularExpression)
        if cleanedText.isEmpty { return false }
        
        // Count Latin characters
        let latinCount = cleanedText.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return (scalar >= 0x0041 && scalar <= 0x005A) || // A-Z
                   (scalar >= 0x0061 && scalar <= 0x007A)    // a-z
        }.count
        
        // If more than 70% of characters are Latin, consider it English/Latin text
        return Double(latinCount) / Double(cleanedText.count) > 0.7
    }
    
    private func determineVerticalLayout() -> Bool {
        // Determine if we should use vertical layout
        // 1. If explicitly marked as vertical text
        if isVerticalText { return true }
        
        // 2. If source is Japanese and box is vertical, and translation is also Japanese
        if sourceLanguage == "ja" && screenBox.height > screenBox.width * 2.0 {
            // Check if translated text is also Japanese (for ja->ja translations)
            if isJapaneseText(translatedText) {
                return true
            }
        }
        
        return false
    }
    
    private func shouldRotateVerticalBox(_ isVerticalBox: Bool, _ text: String) -> Bool {
        // Don't rotate if not a vertical box
        if !isVerticalBox { return false }
        
        // Japanese text uses special vertical layout, not rotation
        if isJapaneseText(text) { return false }
        
        // Korean and English/Latin text should be rotated in vertical boxes
        if isKoreanText(text) || isEnglishOrLatinText(text) {
            return true
        }
        
        // For mixed or unidentified text, rotate if it's not primarily Japanese
        return !isJapaneseText(text)
    }
    
    // MARK: - Styling
    
    private var borderColorByQuality: Color {
        // Quality-based border color for visual feedback
        if qualityScore > 0.8 {
            return Color.green.opacity(0.3)  // High quality: subtle green
        } else if qualityScore > 0.6 {
            return Color.blue.opacity(0.3)   // Good quality: subtle blue
        } else if qualityScore > 0.4 {
            return Color.orange.opacity(0.4) // Medium quality: subtle orange
        } else {
            return Color.red.opacity(0.4)    // Low quality: subtle red
        }
    }
    
    private var backgroundStyle: some ShapeStyle {
        // Adaptive background based on quality score and confidence
        let baseOpacity: Double
        if qualityScore > 0.7 {
            baseOpacity = 0.9  // High quality: more opaque
        } else if qualityScore > 0.5 {
            baseOpacity = 0.8  // Medium quality
        } else {
            baseOpacity = 0.7  // Lower quality: less opaque
        }
        
        // Further adjust by confidence
        let confidenceMultiplier = Double(confidence) * 0.2 + 0.8  // Range: 0.8-1.0
        let finalOpacity = baseOpacity * confidenceMultiplier
        
        return Color.white.opacity(finalOpacity)
    }
    
    private var textColor: Color {
        // High contrast text color
        if confidence > 0.8 {
            return Color.black
        } else {
            return Color.black.opacity(0.9)
        }
    }
    
    private var fontWeight: Font.Weight {
        // Adjust weight based on font size for readability
        if calculatedFontSize < 12 {
            return .semibold
        } else if calculatedFontSize < 16 {
            return .medium
        } else {
            return .regular
        }
    }
    
    private var textWeightForStandard: Font.Weight {
        // Standard mode: Quality-aware font weight
        if qualityScore > 0.8 {
            return .semibold  // High quality: clearer weight
        } else if qualityScore > 0.6 {
            return .medium
        } else {
            return .bold  // Low quality: bolder for visibility
        }
    }
    
    private var textColorForStandard: Color {
        // Standard mode: Bright white with quality-based tinting
        if qualityScore > 0.8 {
            return Color.white  // Pure white for high quality
        } else if qualityScore > 0.6 {
            return Color(white: 0.95)  // Slightly off-white
        } else {
            return Color(white: 0.9).opacity(0.95)  // Softer for low quality
        }
    }
}

// MARK: - Advanced Font Size Calculator

struct FontSizeCalculator {
    /// Calculate optimal font size using UIKit for precise measurement
    /// Optimized for single-line text display
    static func calculateOptimalFontSize(
        for text: String,
        in boxSize: CGSize,
        minSize: CGFloat = 8,
        maxSize: CGFloat = 40
    ) -> CGFloat {
        // Binary search for optimal size
        var low = minSize
        var high = maxSize
        var bestSize = minSize
        
        // Use 95% of both dimensions as constraints
        let maxWidth = boxSize.width * 0.95
        let maxHeight = boxSize.height * 0.95
        
        while high - low > 0.5 {
            let mid = (low + high) / 2
            let font = UIFont.systemFont(ofSize: mid)
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font
            ]
            
            // Calculate text size for single line (no wrapping)
            // Use very large width to get natural single-line width
            let textSize = (text as NSString).boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            ).size
            
            // Check if single-line text fits within both constraints
            if textSize.width <= maxWidth && textSize.height <= maxHeight {
                bestSize = mid
                low = mid
            } else {
                high = mid
            }
        }
        
        return bestSize
    }
}

// MARK: - Vertical Japanese Text Component

struct VerticalJapaneseText: View {
    let text: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let textColor: Color
    let frame: CGSize
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                let char = String(character)
                
                // Check if character should be rotated (punctuation marks)
                if shouldRotateCharacter(char) {
                    Text(char)
                        .font(.system(size: fontSize * 0.9, weight: fontWeight))
                        .foregroundColor(textColor)
                        .rotationEffect(.degrees(90))
                        .frame(width: fontSize, height: fontSize)
                } else if isLatinOrNumber(char) {
                    // Latin characters and numbers: keep horizontal in vertical text (縦中横)
                    Text(char)
                        .font(.system(size: fontSize * 0.8, weight: fontWeight))
                        .foregroundColor(textColor)
                        .frame(width: fontSize, height: fontSize)
                } else {
                    // Regular Japanese characters
                    Text(char)
                        .font(.system(size: fontSize, weight: fontWeight))
                        .foregroundColor(textColor)
                        .frame(width: fontSize, height: fontSize * 1.1)
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 0)
    }
    
    private func shouldRotateCharacter(_ char: String) -> Bool {
        // Japanese punctuation that should be rotated in vertical text
        let rotatableChars = Set(["。", "、", "「", "」", "（", "）", "『", "』", "【", "】"])
        return rotatableChars.contains(char)
    }
    
    private func isLatinOrNumber(_ char: String) -> Bool {
        // Check if character is Latin alphabet or number
        if let scalar = char.unicodeScalars.first {
            return (scalar.value >= 0x0030 && scalar.value <= 0x0039) || // Numbers
                   (scalar.value >= 0x0041 && scalar.value <= 0x005A) || // Uppercase
                   (scalar.value >= 0x0061 && scalar.value <= 0x007A)    // Lowercase
        }
        return false
    }
}

// MARK: - Preview

#if DEBUG
struct BoxTranslationOverlay_Previews: PreviewProvider {
    static var previews: some View {
        BoxTranslationOverlay(
            trackedTexts: [
                {
                    var t1 = TrackedText(
                        text: "Hello World",
                        boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.1),
                        confidence: 0.9
                    )
                    t1.translation = "안녕하세요 세계"
                    t1.bestTranslation = "안녕하세요 세계"
                    t1.isDisplayable = true
                    return t1
                }(),
                {
                    var t2 = TrackedText(
                        text: "Swift Programming",
                        boundingBox: CGRect(x: 0.4, y: 0.5, width: 0.4, height: 0.15),
                        confidence: 0.7
                    )
                    t2.translation = "스위프트 프로그래밍"
                    t2.bestTranslation = "스위프트 프로그래밍"
                    t2.isDisplayable = true
                    return t2
                }()
            ]
        )
        .frame(width: 390, height: 844)
        .background(Color.gray.opacity(0.3))
    }
}

// Helper removed - using direct initialization in preview
#endif