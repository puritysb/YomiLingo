//
//  OCRService.swift
//  ViewLingo-Cam
//
//  Vision Framework OCR service
//

import Vision
import UIKit
@preconcurrency import CoreImage
import SwiftUI  // For ARMode enum

@MainActor
class OCRService: ObservableObject {
    // MARK: - Types
    
    struct RecognizedText: Hashable {
        let text: String
        let confidence: Float
        let boundingBox: CGRect  // Normalized coordinates
        let language: String?
        let isVertical: Bool
        let textOrientation: CGFloat
        
        init(text: String, confidence: Float, boundingBox: CGRect, language: String? = nil, isVertical: Bool = false, textOrientation: CGFloat = 0) {
            self.text = text
            self.confidence = confidence
            self.boundingBox = boundingBox
            self.language = language
            self.isVertical = isVertical
            self.textOrientation = textOrientation
        }
    }
    
    enum RecognitionMode {
        case fast     // Faster but less accurate
        case accurate // Slower but more accurate
    }
    
    // MARK: - Published Properties
    
    @Published var isProcessing = false
    @Published var lastProcessingTime: TimeInterval = 0
    @Published var recognizedTexts: [RecognizedText] = []
    
    // MARK: - Private Properties
    
    private var minimumConfidence: Float = 0.2  // Lower threshold for better detection (made var for AR mode adjustment)
    private let supportedLanguages = ["ko", "en", "ja"]
    private let processingQueue = DispatchQueue(label: "com.viewlingo.ocr", qos: .userInitiated)
    private var recognitionMode: RecognitionMode = .accurate
    var arMode: ARMode = .standard  // Current AR mode for adaptive filtering
    var targetLanguage: String = "ko"  // Target language for OCR optimization
    private var recentJapaneseDetection = false  // Track if Japanese was recently detected
    private var lastJapaneseDetectionTime: Date?
    private var verticalTextRegions: [CGRect] = []  // Track vertical text regions for combining
    
    // MARK: - Vertical Text Detection
    
    /// Detects if a text region is likely vertical Japanese text
    private func isVerticalJapaneseText(_ text: String, boundingBox: CGRect) -> Bool {
        // Check if text contains Japanese characters
        let hasJapanese = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil
        guard hasJapanese else { return false }
        
        // Check aspect ratio - vertical text boxes are typically tall and narrow
        let aspectRatio = boundingBox.height / boundingBox.width
        return aspectRatio > 2.0  // Height is more than twice the width
    }
    
    /// Groups vertically aligned text boxes that likely form a single vertical text column
    private func groupVerticalTextBoxes(_ texts: [RecognizedText]) -> [[RecognizedText]] {
        var groups: [[RecognizedText]] = []
        var processed = Set<Int>()
        
        for (index, text) in texts.enumerated() {
            if processed.contains(index) { continue }
            
            // Check if this is potentially vertical Japanese text
            guard isVerticalJapaneseText(text.text, boundingBox: text.boundingBox) else { continue }
            
            var group = [text]
            processed.insert(index)
            
            // Find other text boxes that are vertically aligned
            for (otherIndex, otherText) in texts.enumerated() {
                if processed.contains(otherIndex) { continue }
                
                // Check if vertically aligned (similar X position)
                let xDiff = abs(text.boundingBox.midX - otherText.boundingBox.midX)
                let isAligned = xDiff < text.boundingBox.width * 0.5
                
                // Check if vertically adjacent
                let yDiff = abs(text.boundingBox.maxY - otherText.boundingBox.minY)
                let isAdjacent = yDiff < text.boundingBox.height * 0.3
                
                if isAligned && (isAdjacent || group.contains { box in
                    abs(box.boundingBox.maxY - otherText.boundingBox.minY) < box.boundingBox.height * 0.3
                }) {
                    group.append(otherText)
                    processed.insert(otherIndex)
                }
            }
            
            if group.count > 1 {
                // Sort by Y position (top to bottom)
                group.sort { $0.boundingBox.minY < $1.boundingBox.minY }
                groups.append(group)
            }
        }
        
        return groups
    }
    
    /// Combines grouped vertical text boxes into single text entries
    private func combineVerticalTextGroups(_ groups: [[RecognizedText]]) -> [RecognizedText] {
        return groups.map { group in
            // Combine text from top to bottom
            let combinedText = group.map { $0.text }.joined()
            
            // Calculate combined bounding box
            let minX = group.map { $0.boundingBox.minX }.min() ?? 0
            let maxX = group.map { $0.boundingBox.maxX }.max() ?? 0
            let minY = group.map { $0.boundingBox.minY }.min() ?? 0
            let maxY = group.map { $0.boundingBox.maxY }.max() ?? 0
            
            let combinedBox = CGRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            
            // Average confidence
            let avgConfidence = group.reduce(0) { $0 + $1.confidence } / Float(group.count)
            
            return RecognizedText(
                text: combinedText,
                confidence: avgConfidence,
                boundingBox: combinedBox,
                language: "ja",
                isVertical: true,
                textOrientation: .pi / 2  // 90 degrees for vertical text
            )
        }
    }
    
    // Short text exceptions for Standard mode
    private let validShortTexts = Set([
        "OK", "OK!", "GO", "UP", "ON", "OFF", "IN", "OUT",
        "YES", "NO", "APP", "API", "URL", "UI", "UX",
        "PDF", "PNG", "JPG", "GIF", "ZIP", "USB",
        "CPU", "GPU", "RAM", "SSD", "HDD", "iOS",
        "AI", "ML", "AR", "VR", "3D", "2D", "HD", "4K",
        "TV", "PC", "Mac", "Win", "PS5", "PS4"
    ])
    
    // MARK: - Configuration
    
    /// Set recognition mode for performance tuning
    func setRecognitionMode(_ mode: RecognitionMode) {
        recognitionMode = mode
        Logger.shared.log(.info, "OCR recognition mode set to: \(mode == .fast ? "Fast" : "Accurate")")
    }
    
    // MARK: - OCR Processing
    
    /// Process image for text recognition with optional region masking
    func processImage(_ image: CIImage, excludeRegions: [CGRect] = [], isARFrame: Bool = false) async {
        await MainActor.run {
            isProcessing = true
        }
        
        let startTime = Date()
        
        // Perform OCR on background queue
        let texts = await withCheckedContinuation { continuation in
            processingQueue.async {
                Task { @MainActor [weak self] in
                    guard let self = self else {
                        continuation.resume(returning: [RecognizedText]())
                        return
                    }
                
                // Create request
                let request = VNRecognizeTextRequest()
                
                // Configure based on mode
                let currentMode = self.recognitionMode
                request.recognitionLevel = currentMode == .fast ? .fast : .accurate
                
                // Dynamic language prioritization based on target language and context
                let targetLang = await MainActor.run { self.targetLanguage }
                
                // For CJK source text detection (when translating TO English), use accurate mode
                if targetLang == "en" {
                    request.recognitionLevel = .accurate  // Force accurate for better CJK recognition
                }
                // For Japanese text detection, always prioritize Japanese and use accurate mode
                else if recentJapaneseDetection || (arMode == .standard && currentMode == .fast) {
                    request.recognitionLevel = .accurate  // Force accurate for Japanese
                }
                
                request.usesLanguageCorrection = true
                
                // Set recognition languages with priority based on target language
                // IMPORTANT: When translating TO English, we need to recognize CJK source text
                // Use all three languages to let Vision determine the best match
                switch targetLang {
                case "en":
                    // Translating TO English → Prioritize CJK source languages
                    // When user wants to translate TO English, the source text is likely Korean or Japanese
                    // Put CJK languages first to ensure proper recognition
                    request.recognitionLanguages = ["ko-KR", "ja-JP", "en-US"]
                    request.automaticallyDetectsLanguage = true  // Allow automatic detection for all languages
                    Logger.shared.log(.debug, "OCR: Prioritizing CJK languages for translation to English")
                case "ko":
                    // Translating TO Korean → Prioritize Japanese/English source text
                    request.recognitionLanguages = ["ja-JP", "en-US", "ko-KR"]
                    request.automaticallyDetectsLanguage = true  // Allow automatic detection
                    Logger.shared.log(.debug, "OCR: Prioritizing Japanese/English for translation to Korean")
                case "ja":
                    // Translating TO Japanese → Prioritize Korean/English source text
                    request.recognitionLanguages = ["ko-KR", "en-US", "ja-JP"]
                    request.automaticallyDetectsLanguage = true  // Allow automatic detection
                    Logger.shared.log(.debug, "OCR: Prioritizing Korean/English for translation to Japanese")
                default:
                    // Fallback: Balanced priority for all languages
                    // Since we don't know the target, prioritize based on recent detections
                    let shouldPrioritizeJapanese = await MainActor.run {
                        self.arMode == .standard || self.hasRecentJapaneseText()
                    }
                    
                    if shouldPrioritizeJapanese {
                        request.recognitionLanguages = ["ja-JP", "ko-KR", "en-US"]
                    } else {
                        // Default: Balanced priority, slightly favoring CJK for better recognition
                        request.recognitionLanguages = ["ko-KR", "ja-JP", "en-US"]
                    }
                    request.automaticallyDetectsLanguage = true  // Allow automatic detection
                    Logger.shared.log(.debug, "OCR: Using balanced language priority")
                }
                
                request.revision = VNRecognizeTextRequestRevision3  // Explicitly use revision 3 for better CJK
                
                // Process image
                let handler = VNImageRequestHandler(ciImage: image, options: [:])
                
                do {
                    try handler.perform([request])
                    
                    // Process results
                    guard let observations = request.results else {
                        continuation.resume(returning: [RecognizedText]())
                        return
                    }
                    
                    var texts: [RecognizedText] = []
                    var debugStats = (total: 0, lowConfidence: 0, invalidText: 0, edgeFiltered: 0, tooSmall: 0, masked: 0)
                    
                    for observation in observations {
                        debugStats.total += 1
                        
                        // Get top 3 candidates for better accuracy
                        let candidates = observation.topCandidates(3)
                        guard !candidates.isEmpty else {
                            continue
                        }
                        
                        let topCandidate = candidates[0]
                        
                        // DEBUG: Log original Vision Framework boundingBox values
                        let box = observation.boundingBox
                        let boxArea = box.width * box.height
                        Logger.shared.log(.debug, """
                            OCR DEBUG - Raw Vision boundingBox:
                              Text: '\(topCandidate.string)'
                              Origin: (\(String(format: "%.4f", box.origin.x)), \(String(format: "%.4f", box.origin.y)))
                              Size: \(String(format: "%.4f", box.width)) × \(String(format: "%.4f", box.height))
                              Area: \(String(format: "%.6f", boxArea)) (\(String(format: "%.4f%%", boxArea * 100)))
                              Confidence: \(topCandidate.confidence)
                            """)
                        
                        // Check confidence - much lower for Japanese text which often has very low confidence
                        // Check if the text might be CJK based on context
                        let text = topCandidate.string
                        let hasJapanese = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil
                        let hasKorean = text.range(of: "[\u{ac00}-\u{d7a3}]", options: .regularExpression) != nil
                        
                        // Use very low threshold for CJK languages
                        let minConfidenceThreshold: Float
                        if hasJapanese {
                            minConfidenceThreshold = 0.01  // Extremely low for Japanese (magazine fonts)
                        } else if hasKorean {
                            // Very low threshold for Korean text (often has low confidence)
                            minConfidenceThreshold = 0.01  // Same as Japanese for better detection
                        } else {
                            minConfidenceThreshold = await MainActor.run {
                                self.arMode == .standard ? 0.1 : self.minimumConfidence
                            }
                        }
                        
                        if topCandidate.confidence < minConfidenceThreshold {
                            debugStats.lowConfidence += 1
                            // Enhanced logging for CJK text filtering
                            if hasJapanese {
                                Logger.shared.log(.warning, "OCR: Japanese text filtered (confidence: \(topCandidate.confidence), threshold: \(minConfidenceThreshold)): '\(topCandidate.string)'")
                            } else if hasKorean {
                                Logger.shared.log(.warning, "OCR: Korean text filtered (confidence: \(topCandidate.confidence), threshold: \(minConfidenceThreshold)): '\(topCandidate.string)'")
                            } else {
                                Logger.shared.log(.debug, "OCR: Low confidence \(topCandidate.confidence) for '\(topCandidate.string.prefix(20))...'")
                            }
                            continue
                        }
                        
                        // Try multi-candidate fusion for better accuracy
                        let candidateData = candidates.map { ($0.string, $0.confidence) }
                        let fusedText = TextRecovery.fuseCandidates(candidateData)
                        
                        // Use fused text if available, otherwise use top candidate
                        var processedText = fusedText ?? topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // When target is English, validate CJK text recognition
                        if targetLang == "en" {
                            // Check if text appears to be misrecognized Korean/Japanese
                            let actuallyJapanese = processedText.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}]", options: .regularExpression) != nil
                            let actuallyKorean = processedText.range(of: "[\u{ac00}-\u{d7a3}\u{3131}-\u{318e}]", options: .regularExpression) != nil
                            
                            // If we have mixed Korean/Japanese or suspicious patterns, try alternative candidates
                            if actuallyJapanese && actuallyKorean && candidates.count > 1 {
                                Logger.shared.log(.debug, "OCR: Mixed Korean/Japanese detected, trying alternative candidates")
                                for candidate in candidates.dropFirst() {
                                    let altText = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let altJapanese = altText.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}]", options: .regularExpression) != nil
                                    let altKorean = altText.range(of: "[\u{ac00}-\u{d7a3}\u{3131}-\u{318e}]", options: .regularExpression) != nil
                                    
                                    // Prefer pure language texts over mixed
                                    if (altJapanese && !altKorean) || (altKorean && !altJapanese) {
                                        processedText = altText
                                        Logger.shared.log(.debug, "OCR: Selected pure language candidate: '\(altText.prefix(20))...'")
                                        break
                                    }
                                }
                            }
                        }
                        
                        // If text has OCR errors, try recovery
                        if processedText.hasOCRErrors {
                            if let recovered = TextRecovery.recoverText(processedText) {
                                Logger.shared.log(.debug, "OCR: Recovered text from '\(processedText)' to '\(recovered)'")
                                processedText = recovered
                            } else {
                                // If recovery failed but we have other candidates, try them
                                for candidate in candidates.dropFirst() {
                                    let candidateText = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if let recovered = TextRecovery.recoverText(candidateText) {
                                        Logger.shared.log(.debug, "OCR: Used alternative candidate: '\(recovered)'")
                                        processedText = recovered
                                        break
                                    }
                                }
                            }
                        }
                        
                        // Filter out invalid texts
                        let isValid = await MainActor.run {
                            self.isValidText(processedText)
                        }
                        if !isValid {
                            debugStats.invalidText += 1
                            Logger.shared.log(.debug, "OCR: Invalid text filtered: '\(processedText)'")
                            continue
                        }
                        
                        // Filter out edge regions - DISABLED due to Vision Framework coordinate issues
                        // Vision sometimes returns x=0.0000 for centered text, causing false positives
                        // Edge filtering disabled to ensure all text is captured reliably
                        /*
                        let edgeThreshold: CGFloat = await MainActor.run {
                            self.arMode == .standard ? 0.005 : 0.02
                        }
                        if !(box.minX > edgeThreshold && box.maxX < (1.0 - edgeThreshold) &&
                             box.minY > edgeThreshold && box.maxY < (1.0 - edgeThreshold)) {
                            debugStats.edgeFiltered += 1
                            Logger.shared.log(.debug, "OCR: Edge filtered at (\(String(format: "%.2f", box.minX)), \(String(format: "%.2f", box.minY)))")
                            continue
                        }
                        */
                        
                        // Temporary: Log suspicious coordinates for debugging
                        if box.minX == 0.0 && box.width > 0.5 {
                            Logger.shared.log(.warning, """
                                OCR: Suspicious coordinates detected (likely Vision bug):
                                  Text: '\(topCandidate.string)'
                                  x=0.0 with width=\(String(format: "%.2f", box.width))
                                  This text is likely centered, not at edge
                                """)
                        }
                        
                        // Filter out small bounding boxes - extra relaxed for Japanese text
                        let textMightBeJapanese = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil
                        
                        let minWidth: CGFloat = await MainActor.run {
                            if textMightBeJapanese {
                                return 0.005  // 0.5% for Japanese text (magazine text can be very small)
                            }
                            return self.arMode == .standard ? 0.015 : 0.02  // 1.5% for Standard, 2% for ARKit
                        }
                        let minHeight: CGFloat = await MainActor.run {
                            if textMightBeJapanese {
                                return 0.004  // 0.4% for Japanese text
                            }
                            return self.arMode == .standard ? 0.01 : 0.015  // 1% for Standard, 1.5% for ARKit
                        }
                        let minArea: CGFloat = await MainActor.run {
                            if textMightBeJapanese {
                                return 0.0008  // 0.08% for Japanese text
                            }
                            return self.arMode == .standard ? 0.002 : 0.0025  // 0.2% for Standard, 0.25% for ARKit
                        }
                        // Note: boxArea already calculated above
                        
                        // Check for obviously invalid boundingBox values first
                        if box.width <= 0 || box.height <= 0 || boxArea <= 0 {
                            debugStats.tooSmall += 1
                            Logger.shared.log(.warning, "OCR: Invalid boundingBox detected - width: \(box.width), height: \(box.height), area: \(boxArea) for text: '\(topCandidate.string)'")
                            continue
                        }
                        
                        // Additional validation: check for suspiciously small boxes for visible text
                        let textLength = topCandidate.string.count
                        if textLength >= 3 && boxArea < 0.00001 { // Less than 0.001%
                            Logger.shared.log(.warning, "OCR: Suspiciously small boundingBox (\(String(format: "%.6f", boxArea))) for \(textLength)-char text: '\(topCandidate.string)'")
                        }
                        
                        if !(box.width > minWidth && box.height > minHeight && boxArea > minArea) {
                            debugStats.tooSmall += 1
                            Logger.shared.log(.debug, "OCR: Size filtered: \(String(format: "%.4f", box.width))×\(String(format: "%.4f", box.height)) (area: \(String(format: "%.6f", boxArea))) vs min: \(String(format: "%.4f", minWidth))×\(String(format: "%.4f", minHeight)) (area: \(String(format: "%.6f", minArea))) for '\(topCandidate.string)'")
                            continue
                        }
                        
                        // Check if this box is in an excluded region (already being tracked)
                        var isExcluded = false
                        for excludeRegion in excludeRegions {
                            let intersection = box.intersection(excludeRegion)
                            if !intersection.isNull {
                                let intersectionArea = intersection.width * intersection.height
                                let boxArea = box.width * box.height
                                // If more than 50% overlaps with excluded region, skip it
                                if intersectionArea / boxArea > 0.5 {
                                    isExcluded = true
                                    debugStats.masked += 1
                                    Logger.shared.log(.debug, "OCR: Masked (in tracked region): '\(text.prefix(20))...'")
                                    break
                                }
                            }
                        }
                        
                        if isExcluded {
                            continue
                        }
                        
                        // Check if this is Japanese text and track it
                        if processedText.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil {
                            await MainActor.run {
                                self.recentJapaneseDetection = true
                                self.lastJapaneseDetectionTime = Date()
                                Logger.shared.log(.info, "✅ OCR: Japanese text successfully detected (conf: \(topCandidate.confidence)): '\(processedText)'")
                            }
                        }
                        
                        // Detect if this is vertical text
                        let isJapaneseText = processedText.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil
                        let aspectRatio = observation.boundingBox.height / observation.boundingBox.width
                        let isVerticalText = isJapaneseText && aspectRatio > 2.0
                        
                        // Use Vision Framework coordinates as-is
                        // ARFrames already provide correct normalized coordinates
                        let correctedBoundingBox = observation.boundingBox
                        
                        // Create recognized text with proper language detection
                        let detectedLanguage = detectLanguage(processedText)
                        let recognizedText = RecognizedText(
                            text: processedText,
                            confidence: topCandidate.confidence,
                            boundingBox: correctedBoundingBox,
                            language: detectedLanguage,
                            isVertical: isVerticalText,
                            textOrientation: isVerticalText ? .pi / 2 : 0
                        )
                        
                        texts.append(recognizedText)
                    }
                    
                    // Log filtering statistics with language breakdown
                    if debugStats.total > 0 {
                        // Count languages in recognized texts
                        var languageCounts: [String: Int] = [:]
                        for text in texts {
                            let t = text.text
                            if t.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil {
                                languageCounts["Japanese", default: 0] += 1
                            } else if t.range(of: "[\u{ac00}-\u{d7a3}]", options: .regularExpression) != nil {
                                languageCounts["Korean", default: 0] += 1
                            } else if t.range(of: "[a-zA-Z]", options: .regularExpression) != nil {
                                languageCounts["English/Other", default: 0] += 1
                            }
                        }
                        
                        Logger.shared.log(.info, """
                            OCR Filter Stats:
                              Total observations: \(debugStats.total)
                              Low confidence: \(debugStats.lowConfidence)
                              Invalid text: \(debugStats.invalidText)
                              Edge filtered: \(debugStats.edgeFiltered)
                              Too small: \(debugStats.tooSmall)
                              Masked (tracked): \(debugStats.masked)
                              Passed: \(texts.count)
                              Languages: \(languageCounts.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                            """)
                    }
                    
                    // Process vertical text groups if Japanese text is detected
                    var finalTexts = texts
                    let hasJapaneseTexts = texts.contains { text in
                        text.text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil
                    }
                    
                    if hasJapaneseTexts {
                        // Group and combine vertical text boxes
                        let verticalGroups = await MainActor.run {
                            self.groupVerticalTextBoxes(texts)
                        }
                        
                        if !verticalGroups.isEmpty {
                            let combinedVerticalTexts = await MainActor.run {
                                self.combineVerticalTextGroups(verticalGroups)
                            }
                            
                            // Remove individual boxes that were combined and add combined texts
                            let combinedIndices = Set(verticalGroups.flatMap { $0 })
                            finalTexts = texts.filter { text in
                                !combinedIndices.contains(where: { $0.text == text.text && $0.boundingBox == text.boundingBox })
                            }
                            finalTexts.append(contentsOf: combinedVerticalTexts)
                            
                            Logger.shared.log(.info, "OCR: Combined \(verticalGroups.count) vertical text groups")
                        }
                    }
                    
                    continuation.resume(returning: finalTexts)
                    
                } catch {
                    Logger.shared.log(.error, "OCR failed: \(error)")
                    continuation.resume(returning: [RecognizedText]())
                }
                }
            }
        }
        
        // Update UI on main thread
        await MainActor.run {
            self.recognizedTexts = texts
            
            // Track vertical text regions for future processing
            self.verticalTextRegions = texts.filter { $0.isVertical }.map { $0.boundingBox }
            
            let duration = Date().timeIntervalSince(startTime)
            self.lastProcessingTime = duration
            self.isProcessing = false
            
            // Calculate average confidence
            let avgConfidence = texts.isEmpty ? 0.0 :
                texts.map { Double($0.confidence) }.reduce(0, +) / Double(texts.count)
            
            Logger.shared.logOCR(
                detected: texts.count,
                confidence: avgConfidence,
                duration: duration
            )
        }
    }
    
    /// Process camera buffer with optional region masking
    func processBuffer(_ buffer: CVPixelBuffer, excludeRegions: [CGRect] = [], isARFrame: Bool = false) async {
        // Convert to CIImage
        let ciImage = CIImage(cvPixelBuffer: buffer)
        
        // Debug: Log buffer dimensions for coordinate analysis
        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        let imageExtent = ciImage.extent
        
        Logger.shared.log(.debug, """
            OCR Buffer DEBUG:
              isARFrame: \(isARFrame)
              CVPixelBuffer dimensions: \(bufferWidth) × \(bufferHeight)
              CIImage extent: \(imageExtent.width) × \(imageExtent.height)
              CIImage origin: (\(imageExtent.origin.x), \(imageExtent.origin.y))
            """)
        
        // ARFrame is already in correct orientation for OCR (landscape)
        // Don't rotate it - process as-is to maintain correct boundingBox coordinates
        if isARFrame {
            Logger.shared.log(.debug, "OCR: Processing ARFrame in native landscape orientation")
        }
        
        await processImage(ciImage, excludeRegions: excludeRegions, isARFrame: isARFrame)
    }
    
    /// Process UIImage
    func processUIImage(_ uiImage: UIImage) async {
        guard let ciImage = CIImage(image: uiImage) else {
            Logger.shared.log(.error, "Failed to convert UIImage to CIImage")
            return
        }
        await processImage(ciImage)
    }
    
    // MARK: - Helper Methods
    
    /// Check if Japanese text was recently detected
    private func hasRecentJapaneseText() -> Bool {
        if let lastTime = lastJapaneseDetectionTime {
            // Consider Japanese recent if detected within last 5 seconds
            return Date().timeIntervalSince(lastTime) < 5.0
        }
        return recentJapaneseDetection
    }
    
    /// Check if text contains Korean or CJK characters
    private func hasKoreanOrCJK(_ text: String) -> Bool {
        // Korean characters
        if text.range(of: "[\u{ac00}-\u{d7a3}\u{3131}-\u{314e}\u{314f}-\u{3163}]", options: .regularExpression) != nil {
            return true
        }
        // Japanese characters (Hiragana, Katakana, Kanji)
        if text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil {
            return true
        }
        // Chinese characters
        if text.range(of: "[\u{4e00}-\u{9fff}]", options: .regularExpression) != nil {
            return true
        }
        return false
    }
    
    /// Validate if text is meaningful (not just numbers/symbols)
    private func isValidText(_ text: String) -> Bool {
        // Try to recover text with broken characters first
        var validationText = text
        if text.contains("￿") {
            if let recovered = TextRecovery.recoverText(text) {
                Logger.shared.log(.debug, "OCR: Validating recovered text: '\(recovered)' (from: '\(text)')")
                validationText = recovered
            } else {
                Logger.shared.log(.debug, "OCR: Broken character (￿) detected and unrecoverable: '\(text)'")
                return false
            }
        }
        
        // Require at least 2 characters for non-CJK text
        let minLength = hasKoreanOrCJK(validationText) ? 1 : 2
        guard validationText.count >= minLength else { return false }
        
        // Filter out common OCR noise patterns
        let noisePatterns = [
            "^[i•]+[0-9]+",     // i•1, i•2, etc.
            "^[y)]+$",           // y), y)), etc.
            "^[\\p{P}\\p{S}]+$", // Pure punctuation/symbols (entire text is only symbols)
            "^[0-9.,]+$",        // Pure numbers
            "^[•·]+$",           // Bullet points only
            "^[\\s]+$",         // Whitespace only
            "^[il1]+$",          // Common OCR confusion (i, l, 1)
            "^[oO0]+$",          // Common OCR confusion (o, O, 0)
            "^[il1•][^a-zA-Z]*$", // i•1 I... patterns
            "^([I\\s]+)+$",      // Repetitive I I I patterns
            "^(.)\\s+\\1(\\s+\\1)*$", // Any repetitive single char pattern (a a a, b b b)
            "[•·]{2,}",          // Consecutive bullets/dots
            "[¥$£€]{2,}",        // Multiple currency symbols
            "[\\*\\)\\(]{3,}"    // Excessive special chars in sequence (removed • to allow Korean titles with separators)
        ]
        
        for pattern in noisePatterns {
            if validationText.range(of: pattern, options: .regularExpression) != nil {
                // Don't filter if it contains CJK characters (might be valid Japanese/Korean/Chinese with symbols)
                if hasKoreanOrCJK(validationText) && pattern != "^[\\p{P}\\p{S}]+$" {
                    continue // Skip this pattern check for CJK text
                }
                return false
            }
        }
        
        // Require at least one actual letter (not just punctuation with numbers)
        let hasLetter = validationText.range(of: "[\\p{L}]", options: .regularExpression) != nil
        if !hasLetter {
            return false
        }
        
        // For very short text (2-3 chars), check exceptions for Enhanced mode
        if validationText.count <= 3 && !hasKoreanOrCJK(validationText) {
            // Standard mode: Allow known valid short texts
            if arMode == .standard {
                let upperText = validationText.uppercased()
                if validShortTexts.contains(upperText) {
                    Logger.shared.log(.debug, "OCR: Enhanced mode allowing short text: '\(validationText)'")
                    return true
                }
            }
            
            let letterCount = validationText.filter { $0.isLetter }.count
            let ratio = Double(letterCount) / Double(validationText.count)
            // Standard mode: More lenient (50% letters)
            let requiredRatio = arMode == .standard ? 0.5 : 0.6
            if ratio < requiredRatio {
                return false
            }
        }
        
        // Check for excessive character repetition
        let uniqueChars = Set(validationText.filter { !$0.isWhitespace })
        if uniqueChars.count < 2 && validationText.count > 3 {
            // Text with only 1 unique character repeated many times
            return false
        }
        
        // Check for patterns like "I I I I" or "a a a a"
        let components = validationText.split(separator: " ")
        if components.count > 2 {
            let uniqueComponents = Set(components)
            if uniqueComponents.count == 1 && components[0].count <= 2 {
                // All components are the same short string
                return false
            }
        }
        
        // Check for garbled text patterns (mix of random symbols and letters)
        let symbolCount = validationText.filter { !$0.isLetter && !$0.isWhitespace && !$0.isNumber }.count
        let letterCount = validationText.filter { $0.isLetter }.count
        
        if letterCount > 0 && symbolCount > 0 {
            let symbolRatio = Double(symbolCount) / Double(validationText.count)
            
            // More lenient for short texts, especially in Standard mode
            let symbolThreshold: Double
            if arMode == .standard {
                // Standard mode: Even more lenient
                if validationText.count <= 5 {
                    symbolThreshold = 0.6  // 60% for very short texts
                } else if validationText.count <= 10 {
                    symbolThreshold = 0.5  // 50% for short texts
                } else {
                    symbolThreshold = 0.4  // 40% for longer texts
                }
            } else {
                // Legacy/ARKit modes
                if validationText.count <= 5 {
                    symbolThreshold = 0.5  // 50% for very short texts
                } else if validationText.count <= 10 {
                    symbolThreshold = 0.4  // 40% for short texts
                } else {
                    symbolThreshold = 0.35 // 35% for longer texts
                }
            }
            
            if symbolRatio > symbolThreshold {
                Logger.shared.log(.debug, "OCR: Garbled text filtered (high symbol ratio \(String(format: "%.1f%%", symbolRatio * 100))): '\(validationText)'")
                return false
            }
            
            // Check for random character sequences that don't form words
            // Look for patterns like "r)•rtbryJbl)fX*" or "I*)1￿1 VRIQ"
            let hasRandomPattern = validationText.range(of: "[\\*\\)\\(\\•\\￿]{2,}", options: .regularExpression) != nil ||
                                   validationText.range(of: "[a-zA-Z][\\*\\$\\#\\@\\!\\?]{2,}[a-zA-Z]", options: .regularExpression) != nil ||
                                   validationText.range(of: "[•·¥$£€￿]{2,}", options: .regularExpression) != nil
            
            if hasRandomPattern {
                Logger.shared.log(.debug, "OCR: Random pattern filtered: '\(validationText)'")
                return false
            }
            
            // Check for excessive mixed case and symbols (like "Vl•WUnY•Q")
            let mixedCaseSymbolPattern = "([A-Z][a-z]*[•·]+){2,}|([a-z]+[A-Z]+[•·]+){2,}"
            if validationText.range(of: mixedCaseSymbolPattern, options: .regularExpression) != nil {
                Logger.shared.log(.debug, "OCR: Mixed case with symbols filtered: '\(validationText)'")
                return false
            }
        }
        
        return true
    }
    
    private func detectLanguage(_ text: String) -> String? {
        // Language detection based on character sets with priority
        let koreanRegex = try? NSRegularExpression(pattern: "[가-힣ㄱ-ㅎㅏ-ㅣ]+")
        let japaneseRegex = try? NSRegularExpression(pattern: "[ぁ-ゔァ-ヴー々〆〤一-龯]+")
        let chineseRegex = try? NSRegularExpression(pattern: "[一-龯]+")
        let latinRegex = try? NSRegularExpression(pattern: "[a-zA-Z]+")
        
        let range = NSRange(location: 0, length: text.utf16.count)
        
        // Count matches for each language
        var koreanCount = 0
        var japaneseCount = 0
        var chineseCount = 0
        var latinCount = 0
        
        if let regex = koreanRegex {
            koreanCount = regex.matches(in: text, range: range).reduce(0) { sum, match in
                sum + match.range.length
            }
        }
        
        if let regex = japaneseRegex {
            japaneseCount = regex.matches(in: text, range: range).reduce(0) { sum, match in
                sum + match.range.length
            }
        }
        
        if let regex = chineseRegex {
            chineseCount = regex.matches(in: text, range: range).reduce(0) { sum, match in
                sum + match.range.length
            }
        }
        
        if let regex = latinRegex {
            latinCount = regex.matches(in: text, range: range).reduce(0) { sum, match in
                sum + match.range.length
            }
        }
        
        // Determine dominant language
        // Korean has priority if it exists (Hangul is distinctive)
        if koreanCount > 0 {
            return "ko"
        }
        
        // Japanese (has both Kana and Kanji)
        if japaneseCount > chineseCount {
            return "ja"
        }
        
        // Chinese (only Kanji/Hanzi, no Kana)
        if chineseCount > 0 && japaneseCount == 0 {
            return "zh"
        }
        
        // Default to English for Latin characters or unknown
        return latinCount > 0 ? "en" : nil
    }
    
    /// Filter texts by confidence
    func filterByConfidence(_ threshold: Float) -> [RecognizedText] {
        return recognizedTexts.filter { $0.confidence >= threshold }
    }
    
    /// Group nearby texts
    func groupNearbyTexts(threshold: CGFloat = 0.05) -> [[RecognizedText]] {
        var groups: [[RecognizedText]] = []
        var processed = Set<Int>()
        
        for (index, text) in recognizedTexts.enumerated() {
            if processed.contains(index) { continue }
            
            var group = [text]
            processed.insert(index)
            
            // Find nearby texts
            for (otherIndex, otherText) in recognizedTexts.enumerated() {
                if processed.contains(otherIndex) { continue }
                
                // Check if texts are nearby
                let distance = calculateDistance(text.boundingBox, otherText.boundingBox)
                if distance < threshold {
                    group.append(otherText)
                    processed.insert(otherIndex)
                }
            }
            
            groups.append(group)
        }
        
        return groups
    }
    
    private func calculateDistance(_ rect1: CGRect, _ rect2: CGRect) -> CGFloat {
        let center1 = CGPoint(x: rect1.midX, y: rect1.midY)
        let center2 = CGPoint(x: rect2.midX, y: rect2.midY)
        
        let dx = center1.x - center2.x
        let dy = center1.y - center2.y
        
        return sqrt(dx * dx + dy * dy)
    }
    
    /// Clear recognized texts
    func clear() {
        recognizedTexts = []
    }
}

// MARK: - OCR Result Extensions

extension OCRService.RecognizedText {
    /// Convert normalized bounding box to screen coordinates
    func screenBoundingBox(for size: CGSize) -> CGRect {
        // Vision coordinates: bottom-left origin, normalized [0,1]
        // Screen coordinates: top-left origin
        
        let x = boundingBox.origin.x * size.width
        let y = (1 - boundingBox.origin.y - boundingBox.height) * size.height
        let width = boundingBox.width * size.width
        let height = boundingBox.height * size.height
        
        let screenRect = CGRect(x: x, y: y, width: width, height: height)
        
        // DEBUG: Log coordinate conversion for analysis
        let normalizedArea = boundingBox.width * boundingBox.height
        let screenArea = width * height
        Logger.shared.log(.debug, """
            Coordinate Conversion DEBUG:
              Text: '\(text)'
              Normalized boundingBox: origin(\(String(format: "%.4f", boundingBox.origin.x)), \(String(format: "%.4f", boundingBox.origin.y))), size(\(String(format: "%.4f", boundingBox.width)) × \(String(format: "%.4f", boundingBox.height)))
              Screen size: \(String(format: "%.0f", size.width)) × \(String(format: "%.0f", size.height))
              Screen boundingBox: origin(\(String(format: "%.0f", x)), \(String(format: "%.0f", y))), size(\(String(format: "%.0f", width)) × \(String(format: "%.0f", height)))
              Area conversion: \(String(format: "%.6f", normalizedArea)) → \(String(format: "%.0f", screenArea)) pixels
            """)
        
        return screenRect
    }
}