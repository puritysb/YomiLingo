//
//  SceneChangeDetector.swift
//  ViewLingo-Cam
//
//  Detects scene changes to intelligently manage text overlay persistence
//

import Foundation
import CoreGraphics

/// Detects significant scene changes to determine when to clear overlays
@MainActor
class SceneChangeDetector: ObservableObject {
    
    // MARK: - Scene State
    
    enum SceneState {
        case stable      // Minimal movement, high persistence
        case moving      // Moderate movement, normal persistence
        case transitioning  // Major scene change, quick cleanup
    }
    
    // MARK: - Published Properties
    
    @Published var currentState: SceneState = .stable
    @Published var sceneChangeScore: Float = 0.0  // 0-1 score of scene change magnitude
    
    // MARK: - Private Properties
    
    // Text tracking history
    private var previousTexts: Set<String> = []
    private var previousTextCount: Int = 0
    private var previousTextPositions: [CGRect] = []
    private var previousAverageConfidence: Float = 0.0
    
    // Scene statistics
    private var framesSinceLastChange: Int = 0
    private var recentChangeScores: [Float] = []  // Rolling window of change scores
    private let scoreWindowSize = 5
    
    // Thresholds - balanced for responsiveness
    private let sceneChangeThreshold: Float = 0.50  // 50% change = scene transition (more sensitive)
    private let movementThreshold: Float = 0.20     // 20% change = moving
    private let stableFramesRequired = 10          // Frames needed to enter stable state
    
    // Screen quadrant tracking for spatial distribution
    private var previousQuadrantDistribution: [Int] = [0, 0, 0, 0]  // TL, TR, BL, BR
    
    // MARK: - Public Methods
    
    /// Analyze new OCR results to detect scene changes
    func analyzeFrame(texts: [OCRService.RecognizedText], trackedTexts: [TrackedText]) -> SceneState {
        
        // Calculate various change metrics
        let textChangeScore = calculateTextChangeScore(texts: texts)
        let positionChangeScore = calculatePositionChangeScore(texts: texts)
        let confidenceChangeScore = calculateConfidenceChangeScore(texts: texts)
        let distributionChangeScore = calculateDistributionChangeScore(texts: texts)
        
        // Weighted combination of scores - adjusted for Japanese text stability
        // Reduce text change weight since Japanese OCR can vary between frames
        let weights: [Float] = [0.2, 0.3, 0.1, 0.4]  // text, position, confidence, distribution
        let totalScore = textChangeScore * weights[0] +
                        positionChangeScore * weights[1] +
                        confidenceChangeScore * weights[2] +
                        distributionChangeScore * weights[3]
        
        // Update rolling window
        recentChangeScores.append(totalScore)
        if recentChangeScores.count > scoreWindowSize {
            recentChangeScores.removeFirst()
        }
        
        // Calculate average recent change
        let averageChange = recentChangeScores.reduce(0, +) / Float(recentChangeScores.count)
        sceneChangeScore = averageChange
        
        // Determine state based on change magnitude with hysteresis
        let newState: SceneState
        
        // Add hysteresis to prevent rapid state changes
        let currentThresholdMultiplier: Float = currentState == .transitioning ? 0.9 : 1.0
        let adjustedSceneThreshold = sceneChangeThreshold * currentThresholdMultiplier
        let adjustedMovementThreshold = movementThreshold * currentThresholdMultiplier
        
        if averageChange > adjustedSceneThreshold {
            // Only transition if change is significant enough
            if currentState != .transitioning || averageChange > sceneChangeThreshold * 1.1 {
                newState = .transitioning
                framesSinceLastChange = 0
                Logger.shared.log(.info, "Scene change detected! Score: \(averageChange)")
            } else {
                newState = currentState  // Stay in current state
            }
        } else if averageChange > adjustedMovementThreshold {
            newState = .moving
            framesSinceLastChange = 0
        } else {
            // Need sustained stability to enter stable state
            framesSinceLastChange += 1
            newState = framesSinceLastChange >= stableFramesRequired ? .stable : .moving
        }
        
        // Update state if changed
        if newState != currentState {
            Logger.shared.log(.debug, "Scene state changed: \(currentState) → \(newState)")
            currentState = newState
        }
        
        // Update history for next frame
        updateHistory(texts: texts)
        
        return currentState
    }
    
    /// Reset detector state (e.g., when switching modes)
    func reset() {
        previousTexts.removeAll()
        previousTextCount = 0
        previousTextPositions.removeAll()
        previousAverageConfidence = 0.0
        previousQuadrantDistribution = [0, 0, 0, 0]
        framesSinceLastChange = 0
        recentChangeScores.removeAll()
        currentState = .stable
        sceneChangeScore = 0.0
        
        Logger.shared.log(.debug, "Scene change detector reset")
    }
    
    /// Get recommended persistence multiplier based on current state
    func getPersistenceMultiplier() -> Double {
        switch currentState {
        case .stable:
            return 1.2  // Slightly longer persistence when stable
        case .moving:
            return 0.8  // Slightly faster cleanup when moving
        case .transitioning:
            return 0.2  // Very aggressive cleanup during scene transitions
        }
    }
    
    // MARK: - Private Methods
    
    private func calculateTextChangeScore(texts: [OCRService.RecognizedText]) -> Float {
        // Compare text content changes
        let currentTexts = Set(texts.map { $0.text })
        
        // Handle first frame
        guard !previousTexts.isEmpty else {
            return 0.0
        }
        
        // Calculate Jaccard distance (1 - Jaccard similarity)
        let intersection = currentTexts.intersection(previousTexts)
        let union = currentTexts.union(previousTexts)
        
        guard !union.isEmpty else { return 0.0 }
        
        let similarity = Float(intersection.count) / Float(union.count)
        return 1.0 - similarity
    }
    
    private func calculatePositionChangeScore(texts: [OCRService.RecognizedText]) -> Float {
        // Compare average position changes
        guard !previousTextPositions.isEmpty else {
            return 0.0
        }
        
        let currentPositions = texts.map { $0.boundingBox }
        
        // Calculate center of mass for current and previous
        let currentCenter = calculateCenterOfMass(boxes: currentPositions)
        let previousCenter = calculateCenterOfMass(boxes: previousTextPositions)
        
        // Calculate normalized distance
        let dx = currentCenter.x - previousCenter.x
        let dy = currentCenter.y - previousCenter.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // Normalize to 0-1 range (diagonal = 1.414, so divide by 1.5)
        return min(Float(distance / 1.5), 1.0)
    }
    
    private func calculateConfidenceChangeScore(texts: [OCRService.RecognizedText]) -> Float {
        // Compare average confidence levels
        guard previousAverageConfidence > 0 else {
            return 0.0
        }
        
        let currentConfidence = texts.isEmpty ? 0.0 :
            texts.reduce(0.0) { $0 + $1.confidence } / Float(texts.count)
        
        // Significant confidence drop might indicate scene change
        let confidenceChange = abs(currentConfidence - previousAverageConfidence)
        return confidenceChange
    }
    
    private func calculateDistributionChangeScore(texts: [OCRService.RecognizedText]) -> Float {
        // Compare spatial distribution across screen quadrants
        let currentDistribution = calculateQuadrantDistribution(texts: texts)
        
        // Calculate distribution difference
        var totalDiff: Float = 0
        for i in 0..<4 {
            let diff = abs(currentDistribution[i] - previousQuadrantDistribution[i])
            totalDiff += Float(diff)
        }
        
        // Normalize by total text count
        let maxCount = max(texts.count, previousTextCount, 1)
        return totalDiff / Float(maxCount * 2)  // *2 because max diff is 2x count
    }
    
    private func calculateCenterOfMass(boxes: [CGRect]) -> CGPoint {
        guard !boxes.isEmpty else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        
        let sumX = boxes.reduce(0.0) { $0 + $1.midX }
        let sumY = boxes.reduce(0.0) { $0 + $1.midY }
        
        return CGPoint(
            x: sumX / CGFloat(boxes.count),
            y: sumY / CGFloat(boxes.count)
        )
    }
    
    private func calculateQuadrantDistribution(texts: [OCRService.RecognizedText]) -> [Int] {
        var distribution = [0, 0, 0, 0]  // TL, TR, BL, BR
        
        for text in texts {
            let x = text.boundingBox.midX
            let y = text.boundingBox.midY
            
            let quadrant: Int
            if x < 0.5 && y < 0.5 {
                quadrant = 0  // Top-left
            } else if x >= 0.5 && y < 0.5 {
                quadrant = 1  // Top-right
            } else if x < 0.5 && y >= 0.5 {
                quadrant = 2  // Bottom-left
            } else {
                quadrant = 3  // Bottom-right
            }
            
            distribution[quadrant] += 1
        }
        
        return distribution
    }
    
    private func updateHistory(texts: [OCRService.RecognizedText]) {
        // Update all historical data
        previousTexts = Set(texts.map { $0.text })
        previousTextCount = texts.count
        previousTextPositions = texts.map { $0.boundingBox }
        previousAverageConfidence = texts.isEmpty ? 0.0 :
            texts.reduce(0.0) { $0 + $1.confidence } / Float(texts.count)
        previousQuadrantDistribution = calculateQuadrantDistribution(texts: texts)
    }
}