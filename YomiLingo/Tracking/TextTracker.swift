//
//  TextTracker.swift
//  ViewLingo-Cam
//
//  AR Text Tracking System for smooth translation overlay
//

import Foundation
import CoreGraphics
import Vision

/// Detection and translation state for progressive loading
enum DetectionState {
    case detected       // OCR detected, no translation yet
    case translating    // Translation in progress
    case translated     // Translation complete
    case failed        // Translation failed
}

/// Represents a tracked text with persistent ID across frames
struct TrackedText: Identifiable {
    let id = UUID()
    var text: String
    var boundingBox: CGRect
    var lastSeen: Date
    var translation: String?
    var confidence: Float
    var framesSinceLastSeen: Int = 0
    var smoothedBox: CGRect  // For smooth animation
    var translationFailed: Bool = false  // Track if translation has failed
    var translationAttempts: Int = 0     // Count translation attempts
    var predictedBox: CGRect?  // For enhanced AR mode motion prediction
    
    // Progressive loading states
    var detectionState: DetectionState = .detected
    var detectedAt: Date = Date()
    var translationStartedAt: Date?
    var isPlaceholder: Bool = true  // Show as placeholder initially
    
    // Quality management for stable AR tracking
    var bestText: String             // Best quality text seen
    var bestConfidence: Float        // Highest confidence achieved
    var bestTranslation: String?     // Best translation result
    var noiseCount: Int = 0          // Times detected as noise
    var qualityScore: Float = 0      // Overall quality score (0-1)
    var stableFrames: Int = 0        // Frames with stable content
    var isDisplayable: Bool = false  // Whether to show on screen
    var isOnScreen: Bool = true      // Whether text is within screen bounds
    
    // Hysteresis for stable on-screen/off-screen detection
    var consecutiveOffScreenFrames: Int = 0  // Consecutive frames detected as off-screen
    var consecutiveOnScreenFrames: Int = 0   // Consecutive frames detected as on-screen
    var suspicionLevel: Float = 0.0          // Gradual suspicion level for fade-out (0.0=confident, 1.0=very suspicious)
    
    // Vertical text properties
    var isVerticalText: Bool = false    // Whether this is vertical text
    var textOrientation: CGFloat = 0    // Text orientation angle
    var sourceLanguage: String? = nil   // Detected source language
    
    // Temporal text fusion
    var textHistory: [(text: String, confidence: Float)] = []  // History of recognized texts
    var fusedText: String?           // Best fused text from history
    
    init(text: String, boundingBox: CGRect, confidence: Float, isVertical: Bool = false, orientation: CGFloat = 0, language: String? = nil) {
        self.text = text
        self.boundingBox = boundingBox
        self.lastSeen = Date()
        self.confidence = confidence
        self.smoothedBox = boundingBox
        
        // Initialize quality management
        self.bestText = text
        self.bestConfidence = confidence
        self.qualityScore = Self.calculateQualityScore(text: text, confidence: confidence)
        self.isDisplayable = qualityScore > 0.4  // Initial display threshold
        self.isOnScreen = true  // Initially assume on screen
        
        // Initialize text history with first observation
        self.textHistory = [(text, confidence)]
        self.fusedText = text
        
        // Initialize progressive loading state
        self.detectionState = .detected
        self.detectedAt = Date()
        
        // Initialize vertical text properties
        self.isVerticalText = isVertical
        self.textOrientation = orientation
        self.sourceLanguage = language
        self.isPlaceholder = true
    }
    
    /// Add new text observation to history and update fused text
    mutating func addTextObservation(_ text: String, confidence: Float) {
        // Add to history (keep last 5 observations)
        textHistory.append((text, confidence))
        if textHistory.count > 5 {
            textHistory.removeFirst()
        }
        
        // Update fused text using TextRecovery
        if let fused = TextRecovery.fuseCandidates(textHistory) {
            fusedText = fused
            
            // Update main text if fusion produced better result
            if fused != self.text && !fused.hasOCRErrors {
                self.text = fused
                self.qualityScore = Self.calculateQualityScore(text: fused, confidence: confidence, translation: translation)
            }
        }
        
        // Update best text if this has higher confidence
        if confidence > bestConfidence {
            bestText = text
            bestConfidence = confidence
        }
    }
    
    /// Calculate quality score for text
    static func calculateQualityScore(text: String, confidence: Float, translation: String? = nil) -> Float {
        var score: Float = 0
        
        // Check for broken characters - immediate penalty
        if text.contains("￿") {
            score -= 0.5
        }
        
        // Confidence score (0-0.3)
        score += confidence * 0.3
        
        // Check for Korean text early for special handling
        let hasKorean = text.range(of: "[\u{ac00}-\u{d7a3}]", options: .regularExpression) != nil
        
        // Length score (0-0.2) - more lenient for Korean
        if hasKorean {
            // Korean text can be meaningful even with just 1-2 characters
            if text.count >= 1 {
                score += 0.2
            }
        } else {
            if text.count >= 3 && text.count <= 100 {
                score += 0.2
            } else if text.count >= 2 {
                score += 0.1
            }
        }
        
        // Character quality (0-0.2) with stricter penalties
        let _ = text.filter { $0.isLetter }.count
        let symbolCount = text.filter { !$0.isLetter && !$0.isWhitespace && !$0.isNumber }.count
        let symbolRatio = Float(symbolCount) / Float(max(1, text.count))
        
        if symbolRatio < 0.15 {
            score += 0.2  // Very few symbols - good
        } else if symbolRatio < 0.25 {
            score += 0.1  // Some symbols - okay
        } else if symbolRatio >= 0.25 {
            score -= 0.3  // Too many symbols - penalty
        }
        
        // Check for specific noise patterns
        let hasConsecutiveBullets = text.range(of: "[•·]{2,}", options: .regularExpression) != nil
        let hasCurrencyNoise = text.range(of: "[¥$£€]{2,}", options: .regularExpression) != nil
        if hasConsecutiveBullets || hasCurrencyNoise {
            score -= 0.2
        }
        
        // Translation available (0-0.3) - INCREASED importance
        if translation != nil && !translation!.isEmpty {
            score += 0.3  // Increased from 0.2
        }
        
        // Korean bonus (0-0.2) - Korean text is almost always valid
        if hasKorean {
            score += 0.2  // Higher bonus for Korean specifically
        }
        // Other CJK bonus (0-0.1)
        else if text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil {
            score += 0.1
        }
        
        return min(1.0, score)
    }
    
    /// Update quality metrics when text changes
    mutating func updateQuality(newText: String, newConfidence: Float) {
        let newScore = Self.calculateQualityScore(text: newText, confidence: newConfidence, translation: translation)
        
        // Update best values if improved
        if newConfidence > bestConfidence {
            bestConfidence = newConfidence
            bestText = newText
        }
        
        // Update quality score with smoothing
        qualityScore = qualityScore * 0.7 + newScore * 0.3
        
        // Update stable frames
        if abs(newScore - qualityScore) < 0.1 {
            stableFrames += 1
        } else {
            stableFrames = 0
        }
        
        // Determine if displayable
        isDisplayable = shouldDisplay()
    }
    
    /// Determine if text should be displayed
    func shouldDisplay() -> Bool {
        // Don't display if marked as noise too many times
        if noiseCount >= 5 {
            return false
        }
        
        // Display if:
        // 1. Has successful translation - HIGHEST PRIORITY
        // If we have a translation, always show it (unless it's clearly noise)
        if bestTranslation != nil && !bestTranslation!.isEmpty {
            return true
        }
        
        // 2. Has good quality score and stable
        if qualityScore > 0.5 && stableFrames >= 2 {
            return true
        }
        
        // 3. High confidence and meaningful text
        if bestConfidence > 0.7 && bestText.count >= 2 {
            return true
        }
        
        // 4. Korean text with ANY confidence (Korean OCR often has lower confidence)
        if bestText.range(of: "[\u{ac00}-\u{d7a3}]", options: .regularExpression) != nil 
           && bestConfidence > 0.3 {  // Lower threshold for Korean
            return true
        }
        
        // 5. Other CJK text with reasonable confidence
        if bestText.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil 
           && bestConfidence > 0.4 {
            return true
        }
        
        return false
    }
    
    /// Update position with smoothing
    mutating func updatePosition(_ newBox: CGRect, smoothingFactor: CGFloat = 0.85, arMode: ARMode = .standard) {
        // Calculate movement distance for adaptive smoothing
        let dx = abs(newBox.origin.x - boundingBox.origin.x)
        let dy = abs(newBox.origin.y - boundingBox.origin.y)
        let movement = sqrt(dx * dx + dy * dy)
        
        // Adjust smoothing based on AR mode - extra sticky for Japanese text
        let hasCJK = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}\u{ac00}-\u{d7a3}]", options: .regularExpression) != nil
        
        var baseFactor: CGFloat
        switch arMode {
        case .standard:
            baseFactor = hasCJK ? 0.65 : 0.75  // Standard 2D tracking with CJK optimization
        case .arkit:
            baseFactor = hasCJK ? 0.6 : 0.65  // ARKit: Faster response for better AR experience
        }
        
        // Adaptive smoothing: larger movements get faster response
        let adaptiveFactor: CGFloat
        if movement > 0.1 {  // Large movement (>10% of screen)
            adaptiveFactor = min(0.95, baseFactor + 0.2)  // Much faster response
        } else if movement > 0.05 {  // Medium movement
            adaptiveFactor = min(0.9, baseFactor + 0.1)
        } else if movement > 0.02 {  // Small movement
            adaptiveFactor = baseFactor
        } else {  // Tiny movement - maximum stability (sticky effect)
            adaptiveFactor = max(0.3, baseFactor - 0.3)  // Very sticky for tiny movements
        }
        
        // Standard mode: Motion prediction with smoothing
        if arMode == .standard {
            // Calculate velocity with damping
            let velocityDamping: CGFloat = 0.7
            let velocity = CGPoint(
                x: (newBox.origin.x - boundingBox.origin.x) * velocityDamping,
                y: (newBox.origin.y - boundingBox.origin.y) * velocityDamping
            )
            
            // Predict next position with momentum
            let momentumFactor: CGFloat = 0.25  // Balanced momentum for standard mode
            predictedBox = CGRect(
                x: newBox.origin.x + velocity.x * momentumFactor,
                y: newBox.origin.y + velocity.y * momentumFactor,
                width: newBox.width,
                height: newBox.height
            )
            
            // For very small movements, keep position completely stable (extra stable for CJK)
            let stableThreshold: CGFloat = hasCJK ? 0.015 : 0.01
            if movement < stableThreshold {
                // Don't update position at all for tiny movements (sticky effect)
                framesSinceLastSeen = 0
                lastSeen = Date()
                return
            }
        }
        
        // Smooth the position change for natural movement
        smoothedBox.origin.x = smoothedBox.origin.x * (1 - adaptiveFactor) + newBox.origin.x * adaptiveFactor
        smoothedBox.origin.y = smoothedBox.origin.y * (1 - adaptiveFactor) + newBox.origin.y * adaptiveFactor
        smoothedBox.size.width = smoothedBox.size.width * (1 - adaptiveFactor) + newBox.size.width * adaptiveFactor
        smoothedBox.size.height = smoothedBox.size.height * (1 - adaptiveFactor) + newBox.size.height * adaptiveFactor
        
        boundingBox = newBox
        lastSeen = Date()
        framesSinceLastSeen = 0
    }
}

/// Manages text tracking across video frames
@MainActor
class TextTracker: ObservableObject {
    @Published var trackedTexts: [TrackedText] = []
    @Published private var updateTrigger = UUID()  // Force UI updates when needed
    var arMode: ARMode = .standard {  // Current AR mode
        didSet {
            Logger.shared.log(.debug, "TextTracker: AR mode set to \(arMode.rawValue)")
            
            // Adjust tracking parameters based on AR mode
            switch arMode {
            case .arkit:
                // ARKit mode: Lower thresholds for faster tracking
                minFramesForNewText = 1  // Promote after just 1 frame
                minFramesForCJKText = 1  // Same for CJK
                pendingTextTimeout = 2.0  // Keep pending longer in ARKit
            case .standard:
                // Standard mode: Lower thresholds for better CJK recognition
                minFramesForNewText = 2  // Reduced from 3 for faster promotion
                minFramesForCJKText = 1  // Reduced from 2 - CJK text often has lower confidence
                pendingTextTimeout = 1.5  // Increased from 1.0 for better retention
            }
        }
    }
    var scenePersistenceMultiplier: Double = 1.0  // Multiplier from scene detector
    
    // AR mode-specific persistence settings with scene-aware adjustments
    private var maxFramesBeforeRemoval: Int {
        let baseFrames: Int
        switch arMode {
        case .standard:
            baseFrames = 8  // ~250ms - faster removal for better responsiveness
        case .arkit:
            baseFrames = 10  // ~330ms - slightly longer for 3D spatial tracking
        }
        
        // Apply scene persistence multiplier
        return Int(Double(baseFrames) * scenePersistenceMultiplier)
    }
    
    private let maxTrackedTexts = 15  // Increased limit for better coverage
    private var maxTextAge: TimeInterval {
        let baseAge: TimeInterval
        switch arMode {
        case .standard:
            baseAge = 3.0   // 3 seconds for faster scene transitions
        case .arkit:
            baseAge = 4.0   // 4 seconds for 3D tracking
        }
        
        // Apply scene persistence multiplier
        return baseAge * scenePersistenceMultiplier
    }
    
    private let iouThreshold: CGFloat = 0.4  // More tolerant of position changes
    private let textSimilarityThreshold: Double = 0.85  // Stricter text matching
    private var activeTextStrings: Set<String> = []  // Track unique text strings
    
    // Spatial duplicate detection parameters
    private var minFramesForNewText: Int = 3  // Minimum frames before adding new text (noise filter)
    private var minFramesForCJKText: Int = 2  // Lower threshold for CJK text
    private var pendingTextTimeout: TimeInterval = 1.0  // Keep pending texts for 1 second (was 0.5)
    private var pendingTexts: [PendingText] = []  // Texts waiting for confirmation
    
    // Structure for texts pending confirmation
    private struct PendingText {
        let text: String
        let boundingBox: CGRect
        let confidence: Float
        var framesSeen: Int = 1
        let firstSeen: Date = Date()
        let isCJK: Bool  // Track if this is CJK text for special handling
        let language: String?  // Language detected by OCR
        
        init(text: String, boundingBox: CGRect, confidence: Float, language: String? = nil) {
            self.text = text
            self.boundingBox = boundingBox
            self.confidence = confidence
            self.language = language
            // Check if text contains CJK characters
            self.isCJK = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}\u{ac00}-\u{d7a3}]", 
                                    options: .regularExpression) != nil
        }
    }
    
    /// Clear all tracked texts
    func clearAllTexts() {
        trackedTexts.removeAll()
        activeTextStrings.removeAll()
        pendingTexts.removeAll()  // Also clear pending texts
        updateTrigger = UUID()  // Force UI update
        Logger.shared.log(.debug, "TextTracker: Cleared all tracked texts")
    }
    
    /// Process new OCR results and update tracked texts
    func processNewTexts(_ newTexts: [OCRService.RecognizedText]) {
        var matchedNewTexts = Set<Int>()
        var updatedTrackedTexts: [TrackedText] = []
        var updatedTextStrings = Set<String>()
        
        // Update existing tracked texts
        for var tracked in trackedTexts {
            var bestMatch: (index: Int, score: Double)?
            
            // Find best matching new text
            for (index, newText) in newTexts.enumerated() {
                guard !matchedNewTexts.contains(index) else { continue }
                
                let score = calculateMatchScore(tracked: tracked, new: newText)
                if score > 0.5 && (bestMatch == nil || score > bestMatch!.score) {  // Increased from 0.35 to 0.5 for stricter matching
                    bestMatch = (index, score)
                }
            }
            
            if let match = bestMatch {
                // Update existing tracked text
                matchedNewTexts.insert(match.index)
                let newText = newTexts[match.index]
                
                // Remove old text from active set
                activeTextStrings.remove(tracked.text)
                
                // Update quality before changing text
                tracked.updateQuality(newText: newText.text, newConfidence: newText.confidence)
                
                // Check if text has changed significantly
                let textSimilarity = calculateTextSimilarity(tracked.text, newText.text)
                
                // Add to temporal fusion history
                tracked.addTextObservation(newText.text, confidence: newText.confidence)
                
                // If text changed significantly, reset translation
                if textSimilarity < 0.7 {  // Less than 70% similar
                    Logger.shared.log(.info, "Text changed significantly: '\(tracked.text.prefix(20))' → '\(newText.text.prefix(20))' (similarity: \(String(format: "%.2f", textSimilarity)))")
                    
                    // Reset translation state for new text
                    tracked.translation = nil
                    tracked.bestTranslation = nil
                    tracked.detectionState = .detected
                    tracked.translationFailed = false
                    tracked.translationAttempts = 0
                    tracked.isPlaceholder = true
                }
                
                // Use fused text if available and better
                if let fusedText = tracked.fusedText, fusedText != tracked.text {
                    // Check if fused text is an improvement
                    if !fusedText.hasOCRErrors && fusedText.count >= 2 {
                        Logger.shared.log(.debug, "TextTracker: Using fused text '\(fusedText)' instead of '\(newText.text)'")
                        tracked.text = fusedText
                    } else {
                        tracked.text = newText.text
                    }
                } else {
                    tracked.text = newText.text
                }
                
                tracked.updatePosition(newText.boundingBox, arMode: arMode)
                tracked.confidence = newText.confidence
                
                // CRITICAL: Check if text is on screen even when matched
                // This ensures texts moving off-screen are detected with hysteresis
                updateOnScreenStatusWithHysteresis(&tracked)
                
                // Add to updated sets
                updatedTrackedTexts.append(tracked)
                updatedTextStrings.insert(tracked.text)
            } else {
                // No match found, increment frames since last seen
                tracked.framesSinceLastSeen += 1
                
                // IMMEDIATE off-screen detection when OCR doesn't find the text
                // If OCR can't see it for 2 frames, it's likely off-screen
                if tracked.framesSinceLastSeen >= 2 {
                    tracked.isOnScreen = false
                    tracked.suspicionLevel = 1.0  // Maximum suspicion for immediate fade
                    Logger.shared.log(.debug, "Text '\(tracked.text.prefix(20))...' marked OFF-SCREEN (not detected by OCR for \(tracked.framesSinceLastSeen) frames)")
                } else {
                    // Still give it a chance with hysteresis for the first frame
                    updateOnScreenStatusWithHysteresis(&tracked)
                }
                let isOnScreen = tracked.isOnScreen
                
                // Different removal criteria based on visibility and AR mode
                let textAge = Date().timeIntervalSince(tracked.lastSeen)
                
                // Mode-specific thresholds
                let frameThreshold: Int
                let ageThreshold: TimeInterval
                
                if arMode == .standard {
                    // Standard: Aggressive removal for off-screen text
                    if isOnScreen {
                        frameThreshold = Int(Double(maxFramesBeforeRemoval) * 1.2)
                        ageThreshold = maxTextAge * 1.2
                    } else {
                        // Very quick removal when off-screen (1-2 frames)
                        frameThreshold = 2
                        ageThreshold = 0.1  // 100ms
                    }
                } else {
                    // ARKit: Keep longer for 3D space continuity
                    frameThreshold = isOnScreen ? Int(Double(maxFramesBeforeRemoval) * 1.5) : maxFramesBeforeRemoval
                    ageThreshold = isOnScreen ? maxTextAge * 1.5 : maxTextAge
                }
                
                // Standard mode: Slight persistence bonus for high-quality texts
                var qualityBonus = 1.0
                if arMode == .standard && tracked.qualityScore > 0.7 {
                    qualityBonus = 1.2  // 20% longer persistence for high quality
                }
                
                // Apply scene persistence multiplier (stable = 2.0, moving = 1.0, transitioning = 0.3)
                let sceneAdjustedFrameThreshold = Int(Double(frameThreshold) * qualityBonus * scenePersistenceMultiplier)
                let sceneAdjustedAgeThreshold = ageThreshold * qualityBonus * scenePersistenceMultiplier
                
                // Mode-specific removal decision
                let shouldRemove: Bool
                
                if arMode == .standard {
                    // Standard: Gradual removal with fade-out
                    if !isOnScreen {
                        // IMMEDIATE removal for off-screen text (100ms)
                        // OCR not detecting = definitely off-screen
                        shouldRemove = tracked.framesSinceLastSeen >= 3 || // ~100ms at 30fps
                                      textAge > 0.15 // 150ms maximum for off-screen text
                    } else {
                        // Normal removal for on-screen text
                        shouldRemove = tracked.framesSinceLastSeen >= sceneAdjustedFrameThreshold ||
                                      (tracked.translationFailed && tracked.framesSinceLastSeen > 5) ||
                                      textAge > sceneAdjustedAgeThreshold
                    }
                } else {
                    // ARKit: Standard removal with longer persistence
                    shouldRemove = tracked.framesSinceLastSeen >= sceneAdjustedFrameThreshold ||
                                  (tracked.translationFailed && tracked.framesSinceLastSeen > 5) ||
                                  textAge > sceneAdjustedAgeThreshold ||
                                  (!isOnScreen && tracked.framesSinceLastSeen > Int(1.0 * scenePersistenceMultiplier)) // Reduced from 3.0
                }
                
                if !shouldRemove {
                    // Standard mode: Maintain position even without new detection
                    if arMode == .standard && tracked.predictedBox != nil {
                        // Use predicted position to maintain smooth tracking
                        tracked.smoothedBox = tracked.predictedBox!
                    }
                    // On-screen status already updated by hysteresis function above
                    updatedTrackedTexts.append(tracked)
                    updatedTextStrings.insert(tracked.text)
                } else {
                    // Remove from active set when text is no longer tracked
                    activeTextStrings.remove(tracked.text)
                }
            }
        }
        
        // Process pending texts (noise filtering)
        processPendingTexts(newTexts: newTexts, matchedIndices: &matchedNewTexts, updatedTexts: &updatedTrackedTexts, updatedStrings: &updatedTextStrings)
        
        // Add new unmatched texts (with spatial and string-based deduplication)
        for (index, newText) in newTexts.enumerated() {
            if !matchedNewTexts.contains(index) {
                // Check if this exact text string is already being tracked
                let normalizedText = newText.text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Skip if we already have this exact text
                if updatedTextStrings.contains(normalizedText) {
                    Logger.shared.log(.debug, "TextTracker: Skipping duplicate text: '\(normalizedText)'")
                    continue
                }
                
                // Check if this is CJK text for relaxed duplicate detection
                let isCJK = normalizedText.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}\u{ac00}-\u{d7a3}]", 
                                                 options: .regularExpression) != nil
                
                // Use relaxed thresholds for CJK text
                let overlapThreshold = isCJK ? 0.4 : 0.5  // 40-50% overlap for definite duplicates
                let partialOverlapThreshold = isCJK ? 0.2 : 0.3  // 20-30% overlap for potential duplicates
                let similarityThreshold = isCJK ? 0.6 : 0.7
                
                // Check for spatial duplicates using IoU (overlapping boxes)
                let hasSpatialDuplicate = updatedTrackedTexts.contains { existing in
                    let overlap = calculateIoU(existing.boundingBox, newText.boundingBox)
                    let textSimilarity = calculateTextSimilarity(normalizedText, existing.text)
                    
                    // Consider it a duplicate if:
                    // 1. High overlap AND reasonably similar text
                    // 2. OR moderate overlap AND very similar text
                    // 3. OR exact same text with any overlap
                    return (overlap > overlapThreshold && textSimilarity > similarityThreshold) ||
                           (overlap > partialOverlapThreshold && textSimilarity > 0.85) ||
                           (textSimilarity > 0.95 && overlap > 0.1)
                }
                
                if hasSpatialDuplicate {
                    Logger.shared.log(.debug, "TextTracker: Skipping spatial duplicate: '\(normalizedText)'")
                    continue
                }
                
                // Check for duplicates considering both text similarity AND position
                // Same text at different positions should be treated as separate
                let hasKorean = normalizedText.range(of: "[\\u{ac00}-\\u{d7a3}]", options: .regularExpression) != nil
                let textSimilarityThreshold = hasKorean ? 0.75 : 0.9  // More forgiving for Korean
                
                // Check if this exact text already exists at a DIFFERENT position
                let hasSameTextAtDifferentPosition = updatedTrackedTexts.contains { existing in
                    let textMatch = existing.text == normalizedText
                    let overlap = calculateIoU(existing.boundingBox, newText.boundingBox)
                    // If same text but no overlap, treat as separate
                    return textMatch && overlap == 0
                }
                
                // Only check for duplicates if it's not the same text at a different position
                let isDuplicate: Bool
                if hasSameTextAtDifferentPosition {
                    // Same text at different position - allow it
                    isDuplicate = false
                    Logger.shared.log(.debug, "TextTracker: Same text '\(normalizedText)' found at different position - treating as separate")
                } else {
                    // Check for similar texts at overlapping positions
                    isDuplicate = updatedTrackedTexts.contains { existing in
                        let similarity = calculateTextSimilarity(normalizedText, existing.text)
                        let overlap = calculateIoU(existing.boundingBox, newText.boundingBox)
                        
                        // Log potential Korean OCR duplicates
                        if hasKorean && similarity > 0.6 && similarity < 0.9 && overlap > 0.2 {
                            Logger.shared.log(.debug, "TextTracker: Potential Korean OCR variation detected: '\(normalizedText)' vs '\(existing.text)' (similarity: \(String(format: "%.2f", similarity)), overlap: \(String(format: "%.2f", overlap)))")
                        }
                        
                        // Consider it duplicate if text is similar AND boxes overlap
                        return similarity > textSimilarityThreshold && overlap > 0.3
                    }
                }
                
                if isDuplicate {
                    Logger.shared.log(.debug, "TextTracker: Skipping similar text: '\(normalizedText)'")
                    continue
                }
                
                // Add to pending texts for noise filtering (must be seen for multiple frames)
                addToPendingTexts(text: normalizedText, box: newText.boundingBox, confidence: newText.confidence, language: newText.language)
            }
        }
        
        // Limit the number of tracked texts
        if updatedTrackedTexts.count > maxTrackedTexts {
            // Sort by last seen time and keep only the most recent ones
            updatedTrackedTexts.sort { $0.lastSeen > $1.lastSeen }
            updatedTrackedTexts = Array(updatedTrackedTexts.prefix(maxTrackedTexts))
            
            // Update active strings to match
            updatedTextStrings = Set(updatedTrackedTexts.map { $0.text })
        }
        
        // Update active text strings set
        activeTextStrings = updatedTextStrings
        
        // Update published property
        trackedTexts = updatedTrackedTexts
        
        // Force UI update if we have displayable texts
        if updatedTrackedTexts.contains(where: { $0.isDisplayable }) {
            updateTrigger = UUID()
        }
        
        // Log if we have too many texts
        if trackedTexts.count > 30 {
            Logger.shared.log(.warning, "TextTracker: High text count: \(trackedTexts.count) texts being tracked")
        }
    }
    
    /// Calculate match score between tracked and new text
    private func calculateMatchScore(tracked: TrackedText, new: OCRService.RecognizedText) -> Double {
        // Text similarity (70% weight) - INCREASED for better text matching
        let textSimilarity = calculateTextSimilarity(tracked.text, new.text)
        let textScore = textSimilarity * 0.7
        
        // Position similarity using IoU (30% weight) - DECREASED to prevent wrong matches
        let iouScore = calculateIoU(tracked.boundingBox, new.boundingBox) * 0.3
        
        // Reject if texts are completely different (prevents "컨셉" → "구덩이" matching)
        if textSimilarity < 0.3 {  // Less than 30% text similarity
            return 0  // Don't match at all
        }
        
        return textScore + iouScore
    }
    
    /// Calculate Intersection over Union for bounding boxes
    private func calculateIoU(_ box1: CGRect, _ box2: CGRect) -> Double {
        let intersection = box1.intersection(box2)
        guard !intersection.isNull else { return 0 }
        
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (box1.width * box1.height) + (box2.width * box2.height) - intersectionArea
        
        return Double(intersectionArea / unionArea)
    }
    
    
    /// Levenshtein distance algorithm for text similarity
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let len1 = s1.count
        let len2 = s2.count
        
        if len1 == 0 { return len2 }
        if len2 == 0 { return len1 }
        
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: len2 + 1), count: len1 + 1)
        
        for i in 0...len1 {
            matrix[i][0] = i
        }
        for j in 0...len2 {
            matrix[0][j] = j
        }
        
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        
        for i in 1...len1 {
            for j in 1...len2 {
                let cost = s1Array[i-1] == s2Array[j-1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,      // deletion
                    matrix[i][j-1] + 1,      // insertion
                    matrix[i-1][j-1] + cost  // substitution
                )
            }
        }
        
        return matrix[len1][len2]
    }
    
    /// Update translations for tracked texts
    func updateTranslations(_ translations: [String: String]) {
        guard !translations.isEmpty else { return }
        // Debug logging for translation matching
        let translationKeys = Set(translations.keys)
        let trackedTexts = self.trackedTexts.map { $0.text }
        let unmatchedTranslations = translationKeys.subtracting(Set(trackedTexts))
        let unmatchedTracked = Set(trackedTexts).subtracting(translationKeys)
        
        if !unmatchedTranslations.isEmpty || !unmatchedTracked.isEmpty {
            Logger.shared.log(.warning, """
                TextTracker: Translation key mismatch detected:
                  Unmatched translations (\(unmatchedTranslations.count)): \(unmatchedTranslations.prefix(3).map { "'\($0.prefix(20))...'" }.joined(separator: ", "))
                  Unmatched tracked (\(unmatchedTracked.count)): \(unmatchedTracked.prefix(3).map { "'\($0.prefix(20))...'" }.joined(separator: ", "))
                """)
        }
        
        for index in self.trackedTexts.indices {
            let originalText = self.trackedTexts[index].text
            var foundTranslation: String? = nil
            var matchedKey: String? = nil
            
            // First try exact match
            if let translation = translations[originalText] {
                foundTranslation = translation
                matchedKey = originalText
            } else {
                // Try fuzzy matching for normalized texts
                let normalizedOriginal = normalizeTextForMatching(originalText)
                
                for (translationKey, translation) in translations {
                    let normalizedKey = normalizeTextForMatching(translationKey)
                    let similarity = calculateTextSimilarity(normalizedOriginal, normalizedKey)
                    
                    // Use 80% similarity threshold for fuzzy matching
                    if similarity >= 0.8 {
                        foundTranslation = translation
                        matchedKey = translationKey
                        Logger.shared.log(.info, """
                            TextTracker: Fuzzy match found (similarity: \(String(format: "%.2f", similarity))):
                              Original: '\(originalText.prefix(30))...'
                              Matched:  '\(translationKey.prefix(30))...'
                            """)
                        break
                    }
                }
                
                // If still no match, log details for debugging
                if foundTranslation == nil {
                    Logger.shared.log(.debug, """
                        TextTracker: No match found for tracked text:
                          Text: '\(originalText.prefix(40))...'
                          Normalized: '\(normalizedOriginal.prefix(40))...'
                          Available keys: \(translations.keys.prefix(3).map { "'\($0.prefix(20))...'" }.joined(separator: ", "))
                        """)
                }
            }
            
            if let translation = foundTranslation {
                // Validate translation quality
                if isValidTranslation(translation, for: originalText) {
                    self.trackedTexts[index].translation = translation
                    self.trackedTexts[index].translationFailed = false
                    
                    // Update state to translated
                    self.trackedTexts[index].detectionState = .translated
                    self.trackedTexts[index].isPlaceholder = false
                    
                    // Update best translation if better
                    if self.trackedTexts[index].bestTranslation == nil || 
                       translation.count > self.trackedTexts[index].bestTranslation!.count {
                        self.trackedTexts[index].bestTranslation = translation
                    }
                    
                    // Recalculate quality score with translation
                    self.trackedTexts[index].qualityScore = TrackedText.calculateQualityScore(
                        text: self.trackedTexts[index].text,
                        confidence: self.trackedTexts[index].confidence,
                        translation: translation
                    )
                    let wasDisplayable = self.trackedTexts[index].isDisplayable
                    self.trackedTexts[index].isDisplayable = self.trackedTexts[index].shouldDisplay()
                    
                    // Log display state changes
                    if !wasDisplayable && self.trackedTexts[index].isDisplayable {
                        Logger.shared.log(.info, """
                            ✅ TextTracker: Text now displayable after translation:
                              Text: '\(originalText.prefix(30))...'
                              Translation: '\(translation.prefix(30))...'
                              Quality: \(String(format: "%.2f", self.trackedTexts[index].qualityScore))
                            """)
                    } else if wasDisplayable && !self.trackedTexts[index].isDisplayable {
                        Logger.shared.log(.warning, """
                            ❌ TextTracker: Text no longer displayable after translation:
                              Text: '\(originalText.prefix(30))...'
                              Quality: \(String(format: "%.2f", self.trackedTexts[index].qualityScore))
                            """)
                    }
                    
                    // Cache the translation using the matched key
                    if let key = matchedKey {
                        TranslationCache.shared.set(translation, for: key)
                    }
                    TranslationCache.shared.set(translation, for: originalText)
                } else {
                    // Invalid translation - treat as noise
                    self.trackedTexts[index].noiseCount += 1
                    self.trackedTexts[index].translationFailed = true
                    self.trackedTexts[index].detectionState = .failed
                    Logger.shared.log(.warning, "TextTracker: Invalid translation for '\(originalText.prefix(20))...': '\(translation.prefix(20))...'")
                }
            } else if translations.keys.contains(where: { normalizeTextForMatching($0) == normalizeTextForMatching(originalText) }) {
                // Translation was attempted but returned empty or failed validation
                self.trackedTexts[index].translationFailed = true
                self.trackedTexts[index].noiseCount += 1
                self.trackedTexts[index].detectionState = .failed
                Logger.shared.log(.debug, "TextTracker: Translation attempted but failed for: '\(originalText.prefix(20))...'")
            }
        }
        
        // Force UI update after translations are applied
        let hasTranslations = self.trackedTexts.contains { $0.translation != nil || $0.bestTranslation != nil }
        if hasTranslations {
            updateTrigger = UUID()
            let translatedCount = self.trackedTexts.filter { $0.translation != nil }.count
            Logger.shared.log(.info, "TextTracker: Force UI update after translations (\(translatedCount) translated)")
        }
    }
    
    /// Normalize text for matching (identical to TranslationService.cleanTextForTranslation)
    private func normalizeTextForMatching(_ text: String) -> String {
        // Remove broken/replacement characters
        var cleaned = text.replacingOccurrences(of: "￿", with: "")
        
        // Remove consecutive special characters (bullets, dots, etc.)
        cleaned = cleaned.replacingOccurrences(of: "[•·]{2,}", with: "", options: .regularExpression)
        
        // Replace excessive special characters with space (keep pipe | for Korean book titles)
        cleaned = cleaned.replacingOccurrences(of: "[^\\p{L}\\p{N}\\s.,!?:;()\\-|]", with: " ", options: .regularExpression)
        
        // Collapse multiple spaces
        cleaned = cleaned.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Calculate text similarity between two strings (0.0 = no match, 1.0 = exact match)
    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        guard !text1.isEmpty && !text2.isEmpty else { return 0.0 }
        
        let longer = text1.count > text2.count ? text1 : text2
        let shorter = text1.count > text2.count ? text2 : text1
        
        // If one text is much shorter, use length ratio as additional factor
        let lengthRatio = Double(shorter.count) / Double(longer.count)
        if lengthRatio < 0.5 {
            return 0.0  // Too different in length
        }
        
        let editDistance = levenshteinDistance(shorter, longer)
        let maxDistance = longer.count
        let similarity = 1.0 - (Double(editDistance) / Double(maxDistance))
        
        // Check if texts contain Korean
        let hasKorean = text1.range(of: "[\\u{ac00}-\\u{d7a3}]", options: .regularExpression) != nil
        
        // For Korean text, be more forgiving with OCR errors like "컨셉"→"컨센"
        if hasKorean {
            // If similarity is already high, boost it
            if similarity > 0.6 {
                // Check for common Korean OCR errors (single character differences)
                if editDistance <= 1 && text1.count == text2.count {
                    // Single character substitution in same-length Korean text
                    // Very likely an OCR error like "셉"→"센"
                    return min(1.0, similarity + 0.25)  // Major boost for likely OCR errors
                }
                return min(1.0, similarity + 0.15)  // General Korean boost
            }
        }
        
        // Boost similarity for CJK text that often has minor variations
        let hasCJK = text1.range(of: "[\\u{3040}-\\u{309f}\\u{30a0}-\\u{30ff}\\u{4e00}-\\u{9faf}\\u{ac00}-\\u{d7a3}]", options: .regularExpression) != nil
        if hasCJK && similarity > 0.7 {
            return min(1.0, similarity + 0.1)  // Boost CJK similarity
        }
        
        return similarity
    }
    
    /// Mark texts as being translated (for progressive loading)
    func markTextsAsTranslating(_ texts: [String]) {
        for index in trackedTexts.indices {
            if texts.contains(trackedTexts[index].text) && trackedTexts[index].detectionState == .detected {
                trackedTexts[index].detectionState = .translating
                trackedTexts[index].translationStartedAt = Date()
            }
        }
    }
    
    /// Validate translation quality
    private func isValidTranslation(_ translation: String, for originalText: String) -> Bool {
        // Empty translation
        if translation.isEmpty {
            return false
        }
        
        // Translation is same as original (no translation happened)
        if translation == originalText {
            return false
        }
        
        // Translation is mostly symbols/punctuation
        let letterCount = translation.filter { $0.isLetter }.count
        if letterCount < translation.count / 3 {
            return false
        }
        
        // Translation is unreasonably long compared to original
        if translation.count > originalText.count * 10 && translation.count > 100 {
            return false
        }
        
        // Translation contains only numbers
        if translation.range(of: "^[0-9\\s.,]+$", options: .regularExpression) != nil {
            return false
        }
        
        return true
    }
    
    /// Mark translation as failed for specific texts
    func markTranslationFailed(for texts: [String]) {
        for index in trackedTexts.indices {
            if texts.contains(trackedTexts[index].text) {
                trackedTexts[index].translationFailed = true
                trackedTexts[index].translationAttempts += 1
            }
        }
    }
    
    /// Clear all tracked texts
    func clear() {
        trackedTexts.removeAll()
        activeTextStrings.removeAll()
        pendingTexts.removeAll()
        updateTrigger = UUID()  // Force UI update on clear
    }
    
    /// Get all tracked regions for OCR masking
    /// Returns slightly expanded boxes to ensure complete coverage
    func getTrackedRegions() -> [CGRect] {
        return trackedTexts.compactMap { tracked in
            // Only return regions that are actively being tracked with good confidence
            guard tracked.framesSinceLastSeen == 0, tracked.confidence > 0.5 else { return nil }
            
            // Expand the box more to prevent duplicate detection
            var expandedBox = tracked.boundingBox
            let expansion: CGFloat = 0.05  // 5% expansion on each side for better coverage
            expandedBox.origin.x = max(0, expandedBox.origin.x - expansion)
            expandedBox.origin.y = max(0, expandedBox.origin.y - expansion)
            expandedBox.size.width = min(1.0 - expandedBox.origin.x, expandedBox.size.width + expansion * 2)
            expandedBox.size.height = min(1.0 - expandedBox.origin.y, expandedBox.size.height + expansion * 2)
            
            return expandedBox
        }
    }
    
    /// Check if a point is within any tracked region
    func isPointInTrackedRegion(_ point: CGPoint) -> Bool {
        for region in getTrackedRegions() {
            if region.contains(point) {
                return true
            }
        }
        return false
    }
    
    /// Check if a box overlaps significantly with tracked regions
    func isBoxInTrackedRegion(_ box: CGRect, overlapThreshold: CGFloat = 0.5) -> Bool {
        for region in getTrackedRegions() {
            let iou = calculateIoU(box, region)
            if iou > overlapThreshold {
                return true
            }
        }
        return false
    }
    
    /// Check if a box is visible on screen (center point + area overlap based)
    private func isBoxOnScreen(_ box: CGRect, margin: CGFloat = 0.1) -> Bool {
        // Box coordinates are normalized (0-1)
        // Apply margin to screen bounds (negative margin = stricter bounds)
        let screenBounds = CGRect(
            x: -margin,
            y: -margin,
            width: 1.0 + margin * 2,
            height: 1.0 + margin * 2
        )
        
        // Check if box intersects with screen at all
        let intersection = box.intersection(screenBounds)
        
        // If no intersection, definitely off-screen
        if intersection.isNull {
            return false
        }
        
        // Calculate how much of the box is visible
        let boxArea = box.width * box.height
        let visibleArea = intersection.width * intersection.height
        let visibilityRatio = boxArea > 0 ? visibleArea / boxArea : 0
        
        // Require at least 10% of the text box to be visible (very strict)
        // Reduced from 20% for faster off-screen detection
        let isOnScreen = visibilityRatio >= 0.1
        
        // Debug logging for off-screen detection
        if !isOnScreen {
            Logger.shared.log(.debug, """
                Text OFF-SCREEN:
                  Box: (\(String(format: "%.3f", box.origin.x)), \(String(format: "%.3f", box.origin.y))) size: \(String(format: "%.3f", box.width))×\(String(format: "%.3f", box.height))
                  Visibility: \(String(format: "%.1f%%", visibilityRatio * 100))
                  Margin: \(String(format: "%.2f", margin))
                """)
        }
        
        return isOnScreen
    }
    
    /// Apply hysteresis to on-screen detection to prevent flickering
    private func updateOnScreenStatusWithHysteresis(_ tracked: inout TrackedText) {
        let screenMargin: CGFloat = arMode == .standard ? -0.05 : 0.0  // Tighter boundary for more accurate detection
        let currentlyDetectedAsOnScreen = isBoxOnScreen(tracked.smoothedBox, margin: screenMargin)
        
        // Update consecutive frame counters
        if currentlyDetectedAsOnScreen {
            tracked.consecutiveOnScreenFrames += 1
            tracked.consecutiveOffScreenFrames = 0
        } else {
            tracked.consecutiveOffScreenFrames += 1
            tracked.consecutiveOnScreenFrames = 0
        }
        
        // Calculate gradual suspicion level for smooth fade-out effect
        // This provides natural visual feedback as text moves off-screen or ages
        if tracked.consecutiveOffScreenFrames > 0 {
            // Slower, more gradual increase for natural fade
            // 0.1 per frame = 10 frames (333ms) to reach full suspicion
            let frameSuspicion = min(1.0, Float(tracked.consecutiveOffScreenFrames) * 0.1)
            
            // Also consider time since last seen for smoother fade
            let timeSinceLastSeen = Date().timeIntervalSince(tracked.lastSeen)
            let timeSuspicion = min(1.0, Float(timeSinceLastSeen) / 2.0) // Full fade after 2 seconds
            
            // Use the higher of frame-based or time-based suspicion
            tracked.suspicionLevel = max(frameSuspicion, timeSuspicion)
        } else if tracked.consecutiveOnScreenFrames > 0 {
            // Immediate confidence restoration when back on screen
            tracked.suspicionLevel = 0.0
        }
        
        // Add suspicion for texts that haven't been detected recently (even if "on-screen")
        // This handles cases where text is in viewport but not being detected
        if tracked.framesSinceLastSeen > 30 { // After 1 second without detection
            let agingSuspicion = min(1.0, Float(tracked.framesSinceLastSeen - 30) * 0.03) // Gradual fade
            tracked.suspicionLevel = max(tracked.suspicionLevel, agingSuspicion)
        }
        
        // Apply hysteresis logic (reduced for faster response)
        let previousState = tracked.isOnScreen
        
        if previousState {
            // Currently on-screen: need only 1 consecutive off-screen detection to change to off-screen (faster removal)
            if tracked.consecutiveOffScreenFrames >= 1 {
                tracked.isOnScreen = false
                Logger.shared.log(.debug, "Text '\(tracked.text.prefix(20))...' changed to OFF-SCREEN after \(tracked.consecutiveOffScreenFrames) consecutive detections (suspicion: \(tracked.suspicionLevel))")
            }
        } else {
            // Currently off-screen: need 1 on-screen detection to change to on-screen
            if tracked.consecutiveOnScreenFrames >= 1 {
                tracked.isOnScreen = true
                Logger.shared.log(.debug, "Text '\(tracked.text.prefix(20))...' changed to ON-SCREEN after \(tracked.consecutiveOnScreenFrames) consecutive detections (suspicion reset: \(tracked.suspicionLevel))")
            }
        }
        
        // Update framesSinceLastSeen based on final on-screen status
        if tracked.isOnScreen {
            tracked.framesSinceLastSeen = 0
        } else {
            tracked.framesSinceLastSeen += 1
        }
    }
    
    /// Add text to pending queue for noise filtering
    private func addToPendingTexts(text: String, box: CGRect, confidence: Float, language: String? = nil) {
        let isCJK = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}\u{ac00}-\u{d7a3}]", 
                               options: .regularExpression) != nil
        
        // Use relaxed thresholds for CJK text
        let similarityThreshold = isCJK ? 0.75 : 0.9  // Lower for CJK
        let overlapThreshold = isCJK ? 0.6 : 0.7  // High overlap for same pending text
        
        // Check if this text is already pending
        if let index = pendingTexts.firstIndex(where: { 
            calculateTextSimilarity($0.text, text) > similarityThreshold &&
            calculateIoU($0.boundingBox, box) > overlapThreshold
        }) {
            // Update existing pending text
            pendingTexts[index].framesSeen += 1
            Logger.shared.log(.debug, "TextTracker: Updated pending \(isCJK ? "CJK" : "text"): '\(text.prefix(20))...' (frames: \(pendingTexts[index].framesSeen))")
        } else {
            // Add new pending text with language information
            let pending = PendingText(text: text, boundingBox: box, confidence: confidence, language: language)
            pendingTexts.append(pending)
            Logger.shared.log(.debug, "TextTracker: Added pending \(isCJK ? "CJK" : "text") [\(language ?? "unknown")]: '\(text.prefix(20))...'")
        }
    }
    
    /// Process pending texts and promote confirmed ones to tracked
    private func processPendingTexts(newTexts: [OCRService.RecognizedText], 
                                    matchedIndices: inout Set<Int>,
                                    updatedTexts: inout [TrackedText],
                                    updatedStrings: inout Set<String>) {
        
        var confirmedPending: [PendingText] = []
        var updatedPending: [PendingText] = []
        
        // Check each pending text
        for var pending in pendingTexts {
            // Look for matching text in current frame
            let matchFound = newTexts.enumerated().contains { index, newText in
                guard !matchedIndices.contains(index) else { return false }
                
                // More lenient matching for CJK text (often has recognition variations)
                let similarityThreshold = pending.isCJK ? 0.75 : 0.85
                let overlapThreshold = pending.isCJK ? 0.4 : 0.5  // Require 40-50% overlap for position match
                
                let textMatch = calculateTextSimilarity(pending.text, newText.text) > similarityThreshold
                let positionMatch = calculateIoU(pending.boundingBox, newText.boundingBox) > overlapThreshold
                
                if textMatch && positionMatch {
                    // Mark this new text as matched
                    matchedIndices.insert(index)
                    return true
                }
                return false
            }
            
            if matchFound {
                pending.framesSeen += 1
                
                // Promote to tracked if seen enough times (lower threshold for CJK)
                let requiredFrames = pending.isCJK ? minFramesForCJKText : minFramesForNewText
                if pending.framesSeen >= requiredFrames {
                    confirmedPending.append(pending)
                    Logger.shared.log(.debug, "TextTracker: Promoting \(pending.isCJK ? "CJK" : "text") after \(pending.framesSeen) frames: '\(pending.text.prefix(20))...'")
                } else {
                    updatedPending.append(pending)
                }
            } else {
                // Remove if too old or not seen recently (longer timeout for CJK)
                let age = Date().timeIntervalSince(pending.firstSeen)
                let timeout = pending.isCJK ? pendingTextTimeout * 1.5 : pendingTextTimeout
                if age < timeout {
                    updatedPending.append(pending)
                } else {
                    Logger.shared.log(.debug, "TextTracker: Removing stale pending \(pending.isCJK ? "CJK" : "text") (age: \(String(format: "%.1f", age))s): '\(pending.text.prefix(20))...'")
                }
            }
        }
        
        // Add confirmed texts to tracked
        for pending in confirmedPending {
            // Detect if this is vertical Japanese text
            let isJapanese = pending.text.range(of: "[\\u{3040}-\\u{309f}\\u{30a0}-\\u{30ff}\\u{4e00}-\\u{9faf}]", options: .regularExpression) != nil
            let aspectRatio = pending.boundingBox.height / pending.boundingBox.width
            let isVertical = isJapanese && aspectRatio > 2.0
            
            var tracked = TrackedText(
                text: pending.text,
                boundingBox: pending.boundingBox,
                confidence: pending.confidence,
                isVertical: isVertical,
                orientation: isVertical ? .pi / 2 : 0,
                language: pending.language  // Use language detected by OCR
            )
            
            // Check for cached translation
            if let cachedTranslation = TranslationCache.shared.get(for: pending.text) {
                tracked.translation = cachedTranslation
                tracked.detectionState = .translated
                tracked.isPlaceholder = false
            } else {
                // New text without translation - show as placeholder
                tracked.detectionState = .detected
                tracked.isPlaceholder = true
            }
            
            updatedTexts.append(tracked)
            updatedStrings.insert(pending.text)
            
            Logger.shared.log(.debug, "TextTracker: Confirmed new text after \(pending.framesSeen) frames: '\(pending.text)' (state: \(tracked.detectionState))")
        }
        
        // Update pending list
        pendingTexts = updatedPending
    }
}

/// Simple translation cache to avoid re-translating same text
class TranslationCache {
    static let shared = TranslationCache()
    private var cache: [String: String] = [:]
    private let maxCacheSize = 100
    
    private init() {}
    
    func get(for text: String) -> String? {
        return cache[text]
    }
    
    func set(_ translation: String, for text: String) {
        cache[text] = translation
        
        // Limit cache size
        if cache.count > maxCacheSize {
            // Remove oldest entries (simple FIFO)
            let toRemove = cache.count - maxCacheSize
            cache.keys.prefix(toRemove).forEach { cache.removeValue(forKey: $0) }
        }
    }
    
    func clear() {
        cache.removeAll()
    }
}