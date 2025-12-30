//
//  AR3DTextManager.swift
//  ViewLingo-Cam
//
//  Manages 3D text entities in AR space with high performance
//

import Foundation
import ARKit
import RealityKit
import Combine

@available(iOS 18.0, *)
@MainActor
class AR3DTextManager: ObservableObject {
    // MARK: - Properties
    
    @Published var activeAnchors: [String: TextAnchor] = [:]
    private var arView: ARView?
    private var cancellables = Set<AnyCancellable>()
    
    // Smoothing for position stability
    private var positionHistory: [String: [SIMD3<Float>]] = [:]
    private let smoothingWindowSize = 5
    
    // Debug mode
    var debugMode = false  // Disable for performance
    private var debugAnchors: [AnchorEntity] = []
    private var debugOverlayEnabled = false  // Disable debug overlays for performance
    
    // Performance optimization - Focused on quality over quantity
    private let maxActiveAnchors = 8    // Increased from 5 for better coverage
    private let maxVisibleTexts = 8     // Show more texts
    private let fadeDistance: Float = 2.5  // Start fading at 2.5 meters
    private let cullDistance: Float = 4.0  // Hide beyond 4 meters
    private let maxVisibleDistance: Float = 5.0  // Remove anchors beyond 5 meters
    private let anchorCleanupAge: TimeInterval = 15.0  // Keep anchors longer (15 seconds)
    private let quickCleanupAge: TimeInterval = 5.0  // Quick cleanup for untracked texts
    private let positionThreshold: Float = 0.1  // Position matching threshold
    private let worldScale: Float = 0.5  // Increased scale for better visibility (5-6cm text at 1m)
    private let fieldOfViewAngle: Float = 60.0  // Field of view for visibility check
    private var lastCleanupTime: Date = Date()  // Track last cleanup
    private let cleanupInterval: TimeInterval = 2.0  // Cleanup every 2 seconds
    
    // Mesh caching for performance
    private var meshCache: [String: MeshResource] = [:]
    private let maxCacheSize = 20
    
    // Text filtering criteria
    private let minimumTextSize: Float = 0.002  // Minimum 0.2% of screen area (lowered for better small text detection)
    private let centerZoneRadius: Float = 0.6  // Focus on 60% radius from center (wider)
    
    // MARK: - Types
    
    struct TextAnchor {
        let id: String
        let originalText: String
        let translatedText: String
        var screenPosition: CGRect  // Normalized screen coordinates (mutable for updates)
        let worldPosition: SIMD3<Float>
        let confidence: Float
        var anchorEntity: AnchorEntity?
        var lastUpdated: Date
        var isPlaceholder: Bool = false  // Track if this is a placeholder anchor
        
        var age: TimeInterval {
            Date().timeIntervalSince(lastUpdated)
        }
    }
    
    // MARK: - Public Methods
    
    func setARView(_ view: ARView) {
        self.arView = view
        Logger.shared.log(.info, "AR3DTextManager: Connected to ARView (Debug mode: \(debugMode))")
        
        // Add debug visualization if enabled
        if debugMode {
            addDebugVisualization(to: view)
            addTestAnchor(to: view)  // Add test anchor to verify rendering
            Logger.shared.log(.info, "AR3D: Debug visualization and test anchor added")
        }
    }
    
    /// Add a test anchor to verify AR rendering is working
    private func addTestAnchor(to arView: ARView) {
        // Create a test anchor 1m in front of camera
        let testPosition = SIMD3<Float>(0, 0, -1.0)  // 1m forward
        let testAnchor = AnchorEntity(world: testPosition)
        testAnchor.name = "test_anchor"
        
        // Create visible test text
        let testMesh = MeshResource.generateText(
            "AR TEST",
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 0.1, weight: .bold)
        )
        
        var testMaterial = UnlitMaterial()
        testMaterial.color = .init(tint: .systemRed)
        
        let testEntity = ModelEntity(mesh: testMesh, materials: [testMaterial])
        testAnchor.addChild(testEntity)
        
        arView.scene.addAnchor(testAnchor)
        Logger.shared.log(.info, "AR3D: Test anchor 'AR TEST' added at (0, 0, -1)")
    }
    
    func updateTexts(_ trackedTexts: [TrackedText]) {
        guard let arView = arView else { 
            Logger.shared.log(.error, "AR3D: ARView is nil, cannot update texts")
            return 
        }
        
        Logger.shared.log(.info, "AR3D: updateTexts called with \(trackedTexts.count) texts")
        
        // Debug: Log all incoming tracked texts
        for (index, tracked) in trackedTexts.enumerated() {
            let area = Float(tracked.boundingBox.width * tracked.boundingBox.height)
            Logger.shared.log(.info, """
                AR3D Input [\(index)]: '\(tracked.text)'
                  State: \(tracked.detectionState)
                  Translation: \(tracked.translation ?? "none")
                  Area: \(String(format: "%.4f", area)) (\(String(format: "%.2f", area * 100))%)
                  Confidence: \(tracked.confidence)
                """)
        }
        
        // Filter and prioritize texts
        let prioritizedTexts = prioritizeTexts(trackedTexts)
        
        Logger.shared.log(.info, "AR3D: Filtered \(trackedTexts.count) texts to \(prioritizedTexts.count) priority texts")
        
        // Log what texts were selected for debugging
        if prioritizedTexts.count > 0 {
            let selectedInfo = prioritizedTexts.prefix(3).map { text in
                let area = Float(text.boundingBox.width * text.boundingBox.height)
                return "'\(text.text)' (conf:\(String(format: "%.2f", text.confidence)), area:\(String(format: "%.3f", area)))"
            }.joined(separator: ", ")
            Logger.shared.log(.info, "AR3D: Selected texts: \(selectedInfo)")
        }
        
        // Limit total anchors
        if activeAnchors.count >= maxActiveAnchors {
            cleanupOldestAnchors(keepCount: 2)  // Keep only 2 when at limit
        }
        
        // Process only prioritized texts
        for tracked in prioritizedTexts {
            // Use normalized text as key (position-independent)
            let normalizedKey = normalizeText(tracked.text)
            
            // Check if we already have an anchor for this text
            if let existing = activeAnchors[normalizedKey] {
                // Check if we need to upgrade from placeholder to translated
                if existing.isPlaceholder && tracked.translation != nil {
                    // Remove placeholder and create full anchor
                    existing.anchorEntity?.removeFromParent()
                    activeAnchors.removeValue(forKey: normalizedKey)
                    
                    if let translation = tracked.translation {
                        createAnchor(for: tracked, translation: translation, in: arView, isPlaceholder: false)
                        Logger.shared.log(.info, "AR3D: Upgraded placeholder to full anchor for '\(tracked.text)'")
                    }
                } else {
                    // Update existing anchor position
                    updateAnchor(existing, with: tracked, in: arView)
                }
            } else if shouldCreateAnchor(for: tracked) && activeAnchors.count < maxActiveAnchors {
                // Create appropriate anchor based on translation state
                if let translation = tracked.translation {
                    // Create full anchor with translation
                    Logger.shared.log(.info, "AR3D: About to call createAnchor for '\(tracked.text)' → '\(translation)'")
                    createAnchor(for: tracked, translation: translation, in: arView, isPlaceholder: false)
                    let area = Float(tracked.boundingBox.width * tracked.boundingBox.height)
                    Logger.shared.log(.info, """
                        AR3D: ✅ Created translated anchor:
                          Text: '\(tracked.text)' → '\(translation)'
                          Area: \(String(format: "%.4f", area)) (\(String(format: "%.1f", area * 100))% of screen)
                          Active anchors: \(activeAnchors.count)
                        """)
                } else if tracked.detectionState == .detected || tracked.detectionState == .translating {
                    // Create placeholder anchor while waiting for translation
                    createAnchor(for: tracked, translation: "...", in: arView, isPlaceholder: true)
                    Logger.shared.log(.info, "AR3D: Creating placeholder anchor for '\(tracked.text)' (state: \(tracked.detectionState))")
                }
            }
        }
        
        // Remove old anchors with position-aware matching
        cleanupOldAnchors(currentTexts: trackedTexts)
    }
    
    /// Prioritize texts based on size, position, and confidence
    private func prioritizeTexts(_ texts: [TrackedText]) -> [TrackedText] {
        // Debug: Log all incoming texts
        for text in texts {
            let area = Float(text.boundingBox.width * text.boundingBox.height)
            Logger.shared.log(.debug, "AR3D Filter Check: '\(text.text)' conf:\(text.confidence) area:\(String(format: "%.4f", area)) trans:\(text.translation ?? "none")")
        }
        
        return texts
            .filter { tracked in
                // Accept texts that are detected, translating, or translated
                guard tracked.translation != nil || 
                      tracked.detectionState == .detected || 
                      tracked.detectionState == .translating else {
                    Logger.shared.log(.debug, "AR3D Filtered: '\(tracked.text)' - not ready (state: \(tracked.detectionState))")
                    return false
                }
                
                // Check minimum size (0.5% of screen area - much lower)
                let area = Float(tracked.boundingBox.width * tracked.boundingBox.height)
                if area < minimumTextSize {
                    Logger.shared.log(.debug, "AR3D Filtered: '\(tracked.text)' - area \(String(format: "%.4f", area)) < \(minimumTextSize)")
                    return false
                }
                
                // Check if near center (within 40% radius)
                let centerX: Float = 0.5
                let centerY: Float = 0.5
                let dx = Float(tracked.boundingBox.midX) - centerX
                let dy = Float(tracked.boundingBox.midY) - centerY
                let _ = sqrt(dx * dx + dy * dy)
                
                // Additional filtering for quality
                // Removed "too short" filter - single character texts are valid in CJK
                
                // Prioritize center texts but don't exclude edge texts entirely
                // Just use this for sorting, not filtering
                if tracked.confidence < 0.25 {
                    Logger.shared.log(.debug, "AR3D Filtered: '\(tracked.text)' - confidence \(tracked.confidence) < 0.25")
                    return false
                }
                
                return true
            }
            .sorted { text1, text2 in
                // Sort by: 1) Size (larger first), 2) Distance from center, 3) Confidence
                let area1 = Float(text1.boundingBox.width * text1.boundingBox.height)
                let area2 = Float(text2.boundingBox.width * text2.boundingBox.height)
                
                // Calculate center distance
                let dx1 = Float(text1.boundingBox.midX) - 0.5
                let dy1 = Float(text1.boundingBox.midY) - 0.5
                let dist1 = sqrt(dx1 * dx1 + dy1 * dy1)
                
                let dx2 = Float(text2.boundingBox.midX) - 0.5
                let dy2 = Float(text2.boundingBox.midY) - 0.5
                let dist2 = sqrt(dx2 * dx2 + dy2 * dy2)
                
                // Content-based scoring bonus
                let capsBonus1: Float = text1.text.uppercased() == text1.text ? 2.0 : 0.0
                let capsBonus2: Float = text2.text.uppercased() == text2.text ? 2.0 : 0.0
                
                // Position bonus (prefer upper portion of screen)
                let upperBonus1: Float = text1.boundingBox.midY < 0.6 ? 1.0 : 0.0
                let upperBonus2: Float = text2.boundingBox.midY < 0.6 ? 1.0 : 0.0
                
                // Composite score (higher is better)
                let score1 = area1 * 10 + (1 - dist1) * 5 + text1.confidence * 2 + capsBonus1 + upperBonus1
                let score2 = area2 * 10 + (1 - dist2) * 5 + text2.confidence * 2 + capsBonus2 + upperBonus2
                
                return score1 > score2
            }
            .prefix(maxVisibleTexts)  // Take only top 5
            .map { $0 }
    }
    
    /// Check if we should create an anchor for this text
    private func shouldCreateAnchor(for tracked: TrackedText) -> Bool {
        // Check confidence (much lower threshold for translated texts)
        guard tracked.confidence >= 0.25 else { return false }
        
        // Check size (using updated minimum of 0.5%)
        let area = Float(tracked.boundingBox.width * tracked.boundingBox.height)
        guard area >= minimumTextSize else { return false }
        
        // Check text length
        guard tracked.text.count >= 3 else { return false }
        
        return true
    }
    
    private func normalizeText(_ text: String) -> String {
        // Remove spaces and special characters for better matching
        return text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "|", with: "l")
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
    }
    
    private func findSimilarAnchorWithPosition(text: String, box: CGRect) -> String? {
        // Find anchor with similar text AND position
        _ = normalizeText(text)  // Not used, kept for future use
        
        for (key, anchor) in activeAnchors {
            // Check text similarity
            if textSimilarity(anchor.originalText, text) > 0.8 {
                // Check position similarity (within threshold)
                let dx = abs(Float(anchor.screenPosition.midX - box.midX))
                let dy = abs(Float(anchor.screenPosition.midY - box.midY))
                
                if dx < positionThreshold && dy < positionThreshold {
                    return key  // Found matching text at similar position
                }
            }
        }
        return nil
    }
    
    private func createAnchorKey(for tracked: TrackedText) -> String {
        // Create unique key combining text and position
        let text = normalizeText(tracked.text)
        let x = Int(tracked.boundingBox.midX * 100)  // Quantize position to avoid float precision issues
        let y = Int(tracked.boundingBox.midY * 100)
        return "\(text)_\(x)_\(y)"
    }
    
    private func textSimilarity(_ text1: String, _ text2: String) -> Float {
        let s1 = normalizeText(text1)
        let s2 = normalizeText(text2)
        
        if s1 == s2 { return 1.0 }
        
        let longer = max(s1.count, s2.count)
        if longer == 0 { return 1.0 }
        
        let editDistance = levenshteinDistance(s1, s2)
        return 1.0 - Float(editDistance) / Float(longer)
    }
    
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let m = s1.count
        let n = s2.count
        
        if m == 0 { return n }
        if n == 0 { return m }
        
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        
        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }
        
        for i in 1...m {
            for j in 1...n {
                let cost = s1[s1.index(s1.startIndex, offsetBy: i-1)] == s2[s2.index(s2.startIndex, offsetBy: j-1)] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,
                    matrix[i][j-1] + 1,
                    matrix[i-1][j-1] + cost
                )
            }
        }
        
        return matrix[m][n]
    }
    
    // MARK: - Private Methods
    
    private func createAnchor(for tracked: TrackedText, translation: String, in arView: ARView, isPlaceholder: Bool = false) {
        // Convert Vision coordinates to screen coordinates
        let screenPoint = convertVisionToScreen(tracked.boundingBox, arView: arView)
        
        // Try raycast with estimated plane instead of existing geometry
        // This allows each text to be placed at its correct position
        let planeResults = arView.raycast(
            from: screenPoint,
            allowing: .estimatedPlane,  // Use estimated plane for better positioning
            alignment: .any
        )
        
        let worldPos: SIMD3<Float>
        var onPlane = false
        var planeNormal: SIMD3<Float>? = nil
        
        if let planeHit = planeResults.first {
            // Place at raycast hit position
            worldPos = SIMD3<Float>(
                planeHit.worldTransform.columns.3.x,
                planeHit.worldTransform.columns.3.y,
                planeHit.worldTransform.columns.3.z
            )
            
            // Extract plane normal (Y-axis of the transform)
            planeNormal = SIMD3<Float>(
                planeHit.worldTransform.columns.1.x,
                planeHit.worldTransform.columns.1.y,
                planeHit.worldTransform.columns.1.z
            )
            
            onPlane = true
            Logger.shared.log(.info, "AR3D: Placing '\(tracked.text)' at raycast position \(worldPos), normal: \(planeNormal!)")
        } else {
            // Fallback to calculated position at fixed distance
            worldPos = calculateWorldPosition(from: tracked.boundingBox, in: arView, isLandscape: true)
            Logger.shared.log(.debug, "AR3D: Using calculated position for '\(tracked.text)' at \(worldPos)")
        }
        
        // Adjust bounding box for portrait orientation if needed
        var adjustedBox = tracked.boundingBox
        let orientation = UIDevice.current.orientation
        let isPortrait = orientation.isPortrait || !orientation.isValidInterfaceOrientation
        
        if isPortrait {
            // In portrait mode, swap dimensions to match the 90° rotation
            adjustedBox = CGRect(
                x: tracked.boundingBox.origin.x,
                y: tracked.boundingBox.origin.y,
                width: tracked.boundingBox.height,   // Swap: height becomes width
                height: tracked.boundingBox.width    // Swap: width becomes height
            )
        }
        
        // Create sticker-like text overlay or placeholder
        Logger.shared.log(.info, "AR3D: Creating \(isPlaceholder ? "placeholder" : "translation") entity for '\(tracked.text)'")
        let stickerEntity: ModelEntity
        if isPlaceholder {
            stickerEntity = createPlaceholderSticker(
                originalText: tracked.text,
                originalBox: adjustedBox,
                confidence: tracked.confidence,
                isTranslating: tracked.detectionState == .translating
            )
            Logger.shared.log(.info, "AR3D: ✅ Placeholder entity created")
        } else {
            stickerEntity = createStickerText(
                translation: translation,
                originalBox: adjustedBox,
                confidence: tracked.confidence,
                onPlane: onPlane
            )
            Logger.shared.log(.info, "AR3D: ✅ Translation entity created for '\(translation)'")
        }
        
        // Create anchor entity
        let anchorEntity = AnchorEntity(world: worldPos)
        anchorEntity.name = tracked.text
        
        // Apply rotation based on detected plane orientation
        if let normal = planeNormal {
            // Check if plane is horizontal (normal pointing up/down) or vertical
            let dotY = abs(normal.y)  // Close to 1 for horizontal planes
            
            // Use stricter threshold (0.98) to prevent slight tilts from triggering rotation
            // This ensures only truly horizontal surfaces (tables, floors) get flat text
            if dotY > 0.98 {
                // Only for true horizontal planes (table, floor) - lay text flat
                stickerEntity.transform.rotation = simd_quatf(angle: -.pi/2, axis: [1, 0, 0])
                Logger.shared.log(.debug, "AR3D: True horizontal plane detected (dotY: \(dotY)), laying text flat")
            } else {
                // Vertical or angled plane (wall, standing book, slightly tilted surfaces) - keep text upright
                // Default: No rotation - text faces camera upright
                Logger.shared.log(.debug, "AR3D: Vertical/angled plane detected (dotY: \(dotY)), keeping text upright")
            }
        } else {
            // No plane detected - default to upright (no rotation)
            // This is better for books and most real-world scenarios
            Logger.shared.log(.debug, "AR3D: No plane detected, keeping text upright")
        }
        
        // Add sticker entity
        anchorEntity.addChild(stickerEntity)
        
        // Add debug corners if enabled
        if debugOverlayEnabled {
            addDebugCorners(for: tracked.boundingBox, worldPos: worldPos, in: arView)
        }
        
        // Skip animation for performance
        // addEntranceAnimation(to: anchorEntity)
        
        // Add to scene
        arView.scene.addAnchor(anchorEntity)
        Logger.shared.log(.info, "AR3D: ✅ Anchor added to ARView.scene for '\(tracked.text)'")
        
        // Verify anchor was added successfully
        let sceneAnchorCount = arView.scene.anchors.count
        Logger.shared.log(.info, "AR3D: Total anchors in scene: \(sceneAnchorCount)")
        
        // Store reference with normalized key
        let normalizedKey = normalizeText(tracked.text)
        let textAnchor = TextAnchor(
            id: normalizedKey,
            originalText: tracked.text,
            translatedText: translation,
            screenPosition: tracked.boundingBox,
            worldPosition: worldPos,
            confidence: tracked.confidence,
            anchorEntity: anchorEntity,
            lastUpdated: Date(),
            isPlaceholder: isPlaceholder
        )
        
        // Use the already defined normalizedKey
        activeAnchors[normalizedKey] = textAnchor
        Logger.shared.log(.info, "AR3D: ✅ TextAnchor stored in activeAnchors dictionary with key '\(normalizedKey)'")
        
        Logger.shared.log(.info, """
            AR3D: 🎯 Anchor creation complete:
              Text: '\(tracked.text)' → '\(translation)'
              BoundingBox: origin(\(String(format: "%.3f", tracked.boundingBox.origin.x)), \(String(format: "%.3f", tracked.boundingBox.origin.y))) size(\(String(format: "%.3f", tracked.boundingBox.width))×\(String(format: "%.3f", tracked.boundingBox.height)))
              Screen Point: (\(String(format: "%.1f", screenPoint.x)), \(String(format: "%.1f", screenPoint.y)))
              World Position: \(worldPos)
              Placeholder: \(isPlaceholder)
              Scene Anchors: \(sceneAnchorCount)
              Active Anchors: \(activeAnchors.count)
            """)
    }
    
    private func updateAnchor(_ anchor: TextAnchor, with tracked: TrackedText, in arView: ARView) {
        // ARKit Optimization: Trust anchor position, don't constantly update
        // Only update metadata for tracking purposes
        let normalizedKey = normalizeText(tracked.text)
        activeAnchors[normalizedKey]?.screenPosition = tracked.boundingBox
        activeAnchors[normalizedKey]?.lastUpdated = Date()
        
        // Don't recalculate or move the anchor - let ARKit handle world tracking
        // This prevents jittering and improves performance
        Logger.shared.log(.debug, "AR3D: Metadata updated for '\(anchor.originalText)' (ARKit maintains position)")
        
        // Original complex update code removed - we trust ARKit's tracking
    }
    
    private func smoothPosition(_ newPosition: SIMD3<Float>, for key: String) -> SIMD3<Float> {
        // Add new position to history
        if positionHistory[key] == nil {
            positionHistory[key] = []
        }
        
        positionHistory[key]?.append(newPosition)
        
        // Keep only recent positions
        if let count = positionHistory[key]?.count, count > smoothingWindowSize {
            positionHistory[key]?.removeFirst(count - smoothingWindowSize)
        }
        
        // Calculate average position
        guard let history = positionHistory[key], !history.isEmpty else {
            return newPosition
        }
        
        let sum = history.reduce(SIMD3<Float>(0, 0, 0), +)
        return sum / Float(history.count)
    }
    
    /// Convert Vision coordinates to screen coordinates for raycast
    private func convertVisionToScreen(_ visionBox: CGRect, arView: ARView) -> CGPoint {
        let screenSize = arView.bounds.size
        
        // Check device orientation for proper coordinate transformation
        let orientation = UIDevice.current.orientation
        let isPortrait = orientation.isPortrait || !orientation.isValidInterfaceOrientation
        
        if isPortrait {
            // Portrait mode: Vision is landscape, screen is portrait
            // Need to rotate coordinates 90 degrees counter-clockwise
            // Vision Y (0-1 bottom to top) → Screen X (0-width left to right)
            // Vision X (0-1 left to right) → Screen Y (0-height top to bottom, inverted)
            let screenX = visionBox.midY * screenSize.width
            let screenY = (1.0 - visionBox.midX) * screenSize.height
            return CGPoint(x: screenX, y: screenY)
        } else {
            // Landscape mode: Direct mapping with Y inversion
            let screenX = visionBox.midX * screenSize.width
            let screenY = (1.0 - visionBox.midY) * screenSize.height
            return CGPoint(x: screenX, y: screenY)
        }
    }
    
    /// Create placeholder sticker for loading state
    private func createPlaceholderSticker(
        originalText: String,
        originalBox: CGRect,
        confidence: Float,
        isTranslating: Bool
    ) -> ModelEntity {
        // Container entity
        let containerEntity = ModelEntity()
        
        // Box dimensions
        let width = Float(originalBox.width) * worldScale
        let height = Float(originalBox.height) * worldScale
        
        // Create wireframe or semi-transparent plane
        let backgroundMesh = MeshResource.generatePlane(
            width: width,
            height: height,
            cornerRadius: 0.005  // Slight rounding
        )
        
        // Placeholder material - lighter and more transparent
        var backgroundMaterial = SimpleMaterial()
        backgroundMaterial.color = SimpleMaterial.BaseColor(
            tint: UIColor(white: 0.3, alpha: isTranslating ? 0.4 : 0.3),  // Lighter gray
            texture: nil
        )
        backgroundMaterial.metallic = 0.0
        backgroundMaterial.roughness = 1.0
        
        let backgroundEntity = ModelEntity(
            mesh: backgroundMesh,
            materials: [backgroundMaterial]
        )
        
        // Create animated border effect for translating state
        if isTranslating {
            // Add pulsing border
            var borderMaterial = SimpleMaterial()
            borderMaterial.color = SimpleMaterial.BaseColor(
                tint: UIColor.systemBlue.withAlphaComponent(0.5),
                texture: nil
            )
            
            // Borders removed for performance
        }
        
        // Add loading text
        let displayText = isTranslating ? "Translating..." : "Detecting..."
        let fontSize = height * 0.5  // Smaller font for placeholder
        
        let textMesh = MeshResource.generateText(
            displayText,
            extrusionDepth: 0.0003,  // Very thin
            font: .systemFont(ofSize: CGFloat(fontSize), weight: .regular)
        )
        
        var textMaterial = SimpleMaterial()
        textMaterial.color = SimpleMaterial.BaseColor(
            tint: UIColor(white: 0.8, alpha: 0.7),  // Light gray text
            texture: nil
        )
        
        let textEntity = ModelEntity(
            mesh: textMesh,
            materials: [textMaterial]
        )
        
        // Center text
        if let textBounds = textEntity.model?.mesh.bounds {
            textEntity.position.x = -textBounds.center.x
            textEntity.position.y = -textBounds.center.y
            textEntity.position.z = 0.001  // Slightly in front
            
            // Scale if needed
            let textWidth = textBounds.max.x - textBounds.min.x
            if textWidth > width * 0.9 {
                let scale = (width * 0.9) / textWidth
                textEntity.scale = SIMD3(repeating: scale)
            }
        }
        
        // Assemble
        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(textEntity)
        
        return containerEntity
    }
    
    /// Create sticker-like text with background
    private func createStickerText(
        translation: String,
        originalBox: CGRect,
        confidence: Float,
        onPlane: Bool
    ) -> ModelEntity {
        // Container entity
        let containerEntity = ModelEntity()
        
        // OCR Box의 정확한 크기 사용 (padding 제거)
        let width = Float(originalBox.width) * worldScale
        let height = Float(originalBox.height) * worldScale
        
        // 네 꼭지점을 정확히 재현하는 평면 생성
        let backgroundMesh = MeshResource.generatePlane(
            width: width,     // 정확한 크기 (padding 제거)
            height: height,
            cornerRadius: 0   // 모서리 둥글기 제거
        )
        
        // 반투명 배경 (더 어둡게)
        var backgroundMaterial = SimpleMaterial()
        backgroundMaterial.color = SimpleMaterial.BaseColor(
            tint: UIColor(white: 0.0, alpha: 0.6),  // 진한 검정, 60% 불투명도
            texture: nil
        )
        backgroundMaterial.metallic = 0.0  // 비금속
        backgroundMaterial.roughness = 1.0  // 무광
        
        let backgroundEntity = ModelEntity(
            mesh: backgroundMesh,
            materials: [backgroundMaterial]
        )
        
        // Ensure background is centered at origin
        backgroundEntity.position = SIMD3<Float>(0, 0, 0)
        
        // Borders removed for performance - background provides sufficient contrast
        
        // 텍스트 크기를 박스에 맞춰 자동 조절
        let charCount = Float(translation.count)
        let _ = width / height
        
        // 예상 텍스트 너비 (한글/영문 평균 고려)
        let estimatedTextWidth = charCount * 0.7  // 평균 글자 너비 비율
        
        // 박스에 맞는 최적 크기 계산 (worldScale 적용 후 크기)
        // Ensure minimum readable size
        var optimalFontSize = max(0.02, height * 0.8)  // 기본: 높이의 80%, 최소 0.02
        
        // 텍스트가 너무 길면 크기 축소
        if estimatedTextWidth * optimalFontSize > width * 0.9 {
            optimalFontSize = (width * 0.9) / estimatedTextWidth
        }
        
        // 최소/최대 크기 제한 (더 큰 최소값 설정)
        optimalFontSize = max(0.015, min(0.1, optimalFontSize))  // Minimum 0.015 for visibility
        
        Logger.shared.log(.debug, """
            AR3D Text Sizing:
              Translation: '\(translation)'
              Box size: \(String(format: "%.3f", width))×\(String(format: "%.3f", height))
              Font size: \(String(format: "%.3f", optimalFontSize))
            """)
        
        // Create text mesh with caching for performance
        let cacheKey = "\(translation)_\(optimalFontSize)"
        let textMesh: MeshResource
        
        if let cachedMesh = meshCache[cacheKey] {
            textMesh = cachedMesh
            Logger.shared.log(.debug, "AR3D: Using cached mesh for '\(translation.prefix(20))...'")
        } else {
            textMesh = MeshResource.generateText(
                translation,
                extrusionDepth: 0.0005,  // 더 얇게
                font: .systemFont(ofSize: CGFloat(optimalFontSize), weight: .bold)
            )
            
            // Add to cache if not full
            if meshCache.count < maxCacheSize {
                meshCache[cacheKey] = textMesh
            } else if meshCache.count >= maxCacheSize {
                // Remove oldest entry (simple FIFO)
                if let firstKey = meshCache.keys.first {
                    meshCache.removeValue(forKey: firstKey)
                }
                meshCache[cacheKey] = textMesh
            }
        }
        
        var textMaterial = SimpleMaterial()
        textMaterial.color = SimpleMaterial.BaseColor(
            tint: UIColor(white: 1.0, alpha: 1.0),  // 완전한 흰색
            texture: nil
        )
        textMaterial.metallic = 0.0
        textMaterial.roughness = 1.0
        
        let textEntity = ModelEntity(
            mesh: textMesh,
            materials: [textMaterial]
        )
        
        // Shadow removed for performance - saves 50ms per text
        
        // Position text slightly in front of background without offset
        // DO NOT center by bounds - this causes text/background separation
        textEntity.position = SIMD3<Float>(0, 0, 0.005)  // Just in front, no X/Y offset
        
        // Scale text if needed to fit within background
        if let textBounds = textEntity.model?.mesh.bounds {
            
            // 텍스트가 박스를 넘지 않도록 추가 스케일 조정
            let textWidth = textBounds.max.x - textBounds.min.x
            let textHeight = textBounds.max.y - textBounds.min.y
            
            let scaleX = width * 0.85 / textWidth   // 85% 여백
            let scaleY = height * 0.85 / textHeight
            let scale = min(scaleX, scaleY, 1.0)    // 1.0 이하로만 축소
            
            if scale < 1.0 {
                textEntity.scale = SIMD3(repeating: scale)
                Logger.shared.log(.debug, "AR3D: Text scaled to \(scale) to fit box")
            }
        }
        
        // Assemble (simplified - only 2 entities instead of 7)
        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(textEntity)
        
        return containerEntity
    }
    
    private func createOptimizedTextMesh(text: String, confidence: Float, boundingBox: CGRect? = nil) -> ModelEntity {
        // Choose font size based on bounding box size
        // Scale based on expected viewing distance (1m)
        let baseFontSize: Float
        
        if let box = boundingBox {
            // Scale font size based on bounding box height
            // The bounding box is in normalized coordinates [0,1]
            // Map to reasonable real-world text sizes
            let boxHeight = Float(box.height)
            // Scale to world units (typical text 2-4cm tall at 1m distance)
            baseFontSize = max(0.02, min(0.04, boxHeight * 1.5))  // Reduced scale for better fit
        } else {
            // Fallback to default size
            baseFontSize = 0.04
        }
        
        // Adjust for long text
        let fontSize: Float = text.count > 20 ? baseFontSize * 0.7 : baseFontSize
        
        // Create text mesh - Optimized for performance
        let textMesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.0005,  // Even less depth for better performance
            font: .systemFont(ofSize: CGFloat(fontSize), weight: .medium)  // Medium weight for performance
        )
        
        // Create material with confidence-based color
        var material = SimpleMaterial()
        let baseColor: UIColor
        
        if confidence > 0.9 {
            baseColor = .systemBlue
        } else if confidence > 0.7 {
            baseColor = .systemTeal
        } else {
            baseColor = .systemGray
        }
        
        material.color = .init(tint: baseColor.withAlphaComponent(0.95))
        material.metallic = 0.0
        material.roughness = 0.8
        
        let textEntity = ModelEntity(mesh: textMesh, materials: [material])
        textEntity.name = "text_\(text)"
        
        // Center the text
        if let bounds = textEntity.model?.mesh.bounds {
            textEntity.position.x = -bounds.center.x
            textEntity.position.y = -bounds.center.y
        }
        
        return textEntity
    }
    
    private func createBackgroundPlane(for text: String, boundingBox: CGRect? = nil) -> ModelEntity {
        // Calculate plane size based on bounding box or text length
        let width: Float
        let height: Float
        
        if let box = boundingBox {
            // Scale plane size based on bounding box dimensions
            // The bounding box is in normalized coordinates [0,1]
            // We need to scale it to world units (meters)
            // Use a more reasonable scale factor for proper overlay size
            let scaleFactor: Float = 1.0  // 1 meter width for full screen width
            width = Float(box.width) * scaleFactor * 1.05  // Only 5% padding for tighter fit
            height = Float(box.height) * scaleFactor * 1.05  // Only 5% padding
        } else {
            // Fallback to text-based sizing
            let charWidth: Float = 0.015  // Much smaller default size
            width = Float(text.count) * charWidth + 0.02
            height = 0.05  // Smaller height
        }
        
        let planeMesh = MeshResource.generatePlane(
            width: width,
            height: height,
            cornerRadius: 0.005
        )
        
        var material = SimpleMaterial()
        material.color = .init(
            tint: UIColor.white.withAlphaComponent(0.9),
            texture: nil
        )
        material.metallic = 0.0
        material.roughness = 1.0
        
        let planeEntity = ModelEntity(mesh: planeMesh, materials: [material])
        planeEntity.position.z = -0.005  // Behind text
        planeEntity.name = "bg_\(text)"
        
        // Add subtle shadow
        planeEntity.components[GroundingShadowComponent.self] = GroundingShadowComponent(
            castsShadow: true,
            receivesShadow: false
        )
        
        return planeEntity
    }
    
    private func calculateWorldPosition(from screenRect: CGRect, in arView: ARView, isLandscape: Bool = false) -> SIMD3<Float> {
        // Use ARKit's unproject method for accurate screen-to-world mapping
        guard let frame = arView.session.currentFrame else {
            // Fallback to fixed position if no camera
            let x = Float((screenRect.midX - 0.5) * 2) * 0.5
            let y = Float((0.5 - screenRect.midY) * 2) * 0.4
            return SIMD3(x, y, -1.0)
        }
        
        let camera = frame.camera
        
        // Get screen dimensions
        let screenSize = arView.bounds.size
        let screenWidth = Float(screenSize.width)
        let screenHeight = Float(screenSize.height)
        
        // CRITICAL: Vision Framework coordinate system explanation
        // ================================================
        // Vision Framework (when processing ARFrame.capturedImage):
        // - Origin: Bottom-left (0,0)
        // - Coordinates: Normalized [0,1]
        // - Orientation: ALWAYS landscape (1920x1440 for iPhone)
        // - X-axis: Left to right (0→1)
        // - Y-axis: Bottom to top (0→1)
        //
        // Device Screen (UIKit/ARKit):
        // - Origin: Top-left (0,0)
        // - Coordinates: Pixels (0→width, 0→height)
        // - Orientation: Can be portrait or landscape
        // - X-axis: Left to right
        // - Y-axis: Top to bottom
        
        // Get Vision coordinates (always in landscape space)
        let visionX = Float(screenRect.midX)  // 0-1 normalized (left to right)
        let visionY = Float(screenRect.midY)  // 0-1 normalized (bottom to top)
        
        // Determine device orientation
        let orientation = UIDevice.current.orientation
        let isPortrait = orientation.isPortrait || !orientation.isValidInterfaceOrientation
        
        // Transform Vision coordinates to screen coordinates
        let screenPoint: CGPoint
        
        if isPortrait {
            // PORTRAIT MODE TRANSFORMATION - FIXED
            // =====================================
            // The camera captures in landscape but we display in portrait
            // This requires rotating the coordinate system by 90 degrees COUNTER-CLOCKWISE
            // 
            // CRITICAL FIX: Using counter-clockwise rotation for correct mapping
            // 
            // Vision (Landscape):        Device (Portrait):
            // ┌─────────────┐           ┌──────┐
            // │      ↑Y=1   │           │(0,0) │
            // │      │      │    →      │  ↓Y  │
            // │ ←────┼────→ │           │  │   │
            // │ X=0  │  X=1 │           │──┼──→│
            // │(0,0) ↓Y=0   │           │  │ X │
            // └─────────────┘           └──────┘
            //   Bottom-left              Top-left
            //
            // For 90° COUNTER-CLOCKWISE rotation:
            // - Vision X (horizontal) → Screen Y (vertical)
            // - Vision Y (vertical) → Screen X (horizontal)
            //
            // Transformation:
            //   screenX = visionY × screenWidth
            //   screenY = visionX × screenHeight (no inversion for ARKit)
            
            let screenX = CGFloat(visionY) * CGFloat(screenWidth)    // Vision Y → Screen X
            let screenY = CGFloat(visionX) * CGFloat(screenHeight)   // Vision X → Screen Y (no inversion)
            screenPoint = CGPoint(x: screenX, y: screenY)
            
            // Enhanced debug logging for position tracking
            let percentX = Int((screenX / CGFloat(screenWidth)) * 100)
            let percentY = Int((screenY / CGFloat(screenHeight)) * 100)
            Logger.shared.log(.info, """
                🔄 Portrait Transform:
                   Vision: (\(String(format: "%.3f", visionX)), \(String(format: "%.3f", visionY)))
                   Screen: (\(String(format: "%.1f", screenX)), \(String(format: "%.1f", screenY)))
                   Percent: \(percentX)% from left, \(percentY)% from top
                   BBox Size: \(String(format: "%.3f", screenRect.width))×\(String(format: "%.3f", screenRect.height))
                """)
        } else {
            // LANDSCAPE MODE TRANSFORMATION
            // =============================
            // Camera and display are both in landscape
            // Only need to flip Y axis for coordinate origin difference
            
            let screenX = CGFloat(visionX) * CGFloat(screenWidth)
            let screenY = CGFloat(1.0 - visionY) * CGFloat(screenHeight)  // Flip Y: bottom-left → top-left
            screenPoint = CGPoint(x: screenX, y: screenY)
            
            Logger.shared.log(.debug, "Landscape transform: Vision(\(String(format: "%.3f", visionX)),\(String(format: "%.3f", visionY))) → Screen(\(String(format: "%.1f", screenX)),\(String(format: "%.1f", screenY)))")
        }
        
        // Step 3: Use raycast for accurate unprojection
        // Create a ray from the camera through the screen point
        let results = arView.raycast(
            from: screenPoint,
            allowing: .estimatedPlane,
            alignment: .any
        )
        
        var worldPosition: SIMD3<Float>
        
        if let firstResult = results.first {
            // Use the hit point if we hit a plane
            let hitPosition = SIMD3<Float>(
                firstResult.worldTransform.columns.3.x,
                firstResult.worldTransform.columns.3.y,
                firstResult.worldTransform.columns.3.z
            )
            
            // CRITICAL FIX: Ensure position is in FRONT of camera
            // In ARKit, negative Z is forward from camera
            if hitPosition.z > 0 {
                // Behind camera - force to front
                Logger.shared.log(.warning, "AR3D: Raycast hit behind camera (Z=\(hitPosition.z)), forcing to front")
                worldPosition = SIMD3<Float>(
                    hitPosition.x,
                    hitPosition.y,
                    -abs(hitPosition.z)  // Force negative Z
                )
            } else {
                worldPosition = hitPosition
            }
        } else {
            // No plane hit - use camera-relative positioning
            // This creates a virtual plane at a fixed distance from the camera
            
            // Convert screen point to NDC (Normalized Device Coordinates)
            // NDC ranges from -1 to 1 in both axes
            _ = Float(screenPoint.x / CGFloat(screenWidth)) * 2.0 - 1.0  // ndcX - not used
            _ = 1.0 - Float(screenPoint.y / CGFloat(screenHeight)) * 2.0  // ndcY - not used
            
            // Dynamic distance based on text size for better visibility
            let textArea = Float(screenRect.width * screenRect.height)
            let distance: Float = textArea > 0.04 ? -0.8 : -1.0  // Closer for larger text
            
            // Use camera's field of view for accurate projection
            // Get intrinsics from camera
            let intrinsics = camera.intrinsics
            let imageResolution = camera.imageResolution
            
            // Calculate the ray direction in camera space
            // Using proper camera intrinsics for accurate unprojection
            let fx = intrinsics[0, 0]  // Focal length X
            let fy = intrinsics[1, 1]  // Focal length Y
            let cx = intrinsics[2, 0]  // Principal point X
            let cy = intrinsics[2, 1]  // Principal point Y
            
            // Convert screen coordinates to image coordinates
            // Account for aspect ratio difference between camera and screen
            _ = screenWidth / screenHeight  // screenAspect - unused
            _ = Float(imageResolution.width) / Float(imageResolution.height)  // imageAspect - unused
            
            // Map screen point to image coordinates
            var imageX: Float
            var imageY: Float
            
            if isPortrait {
                // In portrait, the image is rotated 90 degrees COUNTER-CLOCKWISE
                // Screen coordinates need to map back to image coordinates
                // Screen X (horizontal) maps to Image Y (vertical in landscape)
                // Screen Y (vertical) maps to Image X (horizontal in landscape, inverted)
                imageY = Float(screenPoint.x / CGFloat(screenWidth)) * Float(imageResolution.height)
                imageX = Float(1.0 - screenPoint.y / CGFloat(screenHeight)) * Float(imageResolution.width)
            } else {
                // In landscape, direct mapping
                imageX = Float(screenPoint.x / CGFloat(screenWidth)) * Float(imageResolution.width)
                imageY = Float(screenPoint.y / CGFloat(screenHeight)) * Float(imageResolution.height)
            }
            
            // Unproject using camera intrinsics
            // This gives us the ray direction in camera space
            let dirX = (imageX - cx) / fx
            let dirY = (imageY - cy) / fy
            let dirZ: Float = 1.0
            
            // Normalize the direction
            let dirLength = sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)
            let normalizedDir = SIMD3<Float>(dirX / dirLength, dirY / dirLength, dirZ / dirLength)
            
            // Calculate position along the ray at desired distance
            // Use absolute value of distance for calculations
            let absDist = abs(distance)
            let cameraX = normalizedDir.x * absDist
            let cameraY = normalizedDir.y * absDist
            let cameraZ = distance  // Already negative for forward
            
            // Transform from camera space to world space
            let cameraTransform = camera.transform
            let cameraPoint = SIMD4<Float>(cameraX, cameraY, cameraZ, 1.0)
            let worldPoint = cameraTransform * cameraPoint
            worldPosition = worldPoint.xyz
        }
        
        // CRITICAL: Verify Z is negative (in front of camera)
        if worldPosition.z > 0 {
            Logger.shared.log(.error, "AR3D ERROR: World position is BEHIND camera! Z=\(worldPosition.z)")
            // Force to front
            worldPosition.z = -1.0
        }
        
        // Enhanced debug logging
        Logger.shared.log(.debug, """
            AR3D Transform Details:
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            📦 Input BoundingBox:
               Center: (\(String(format: "%.3f", screenRect.midX)), \(String(format: "%.3f", screenRect.midY)))
               Size: \(String(format: "%.3f", screenRect.width)) × \(String(format: "%.3f", screenRect.height))
            📍 Vision Coordinates (Landscape, Bottom-left):
               X: \(String(format: "%.3f", visionX)) (left→right)
               Y: \(String(format: "%.3f", visionY)) (bottom→top)
            📱 Screen Point (\(isPortrait ? "Portrait" : "Landscape"), Top-left):
               X: \(String(format: "%.1f", screenPoint.x)) px
               Y: \(String(format: "%.1f", screenPoint.y)) px
               Size: \(String(format: "%.0f", screenWidth)) × \(String(format: "%.0f", screenHeight)) px
            🎯 Raycast: \(results.first != nil ? "✅ Hit plane" : "❌ No hit (using camera projection)")
            🌍 World Position:
               X: \(String(format: "%+.3f", worldPosition.x)) m (\(worldPosition.x > 0 ? "right" : "left"))
               Y: \(String(format: "%+.3f", worldPosition.y)) m (\(worldPosition.y > 0 ? "up" : "down"))
               Z: \(String(format: "%+.3f", worldPosition.z)) m (\(worldPosition.z < 0 ? "✅ FORWARD" : "❌ BACKWARD"))
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            """)
        
        return worldPosition
    }
    
    private func addEntranceAnimation(to entity: AnchorEntity) {
        // Simple fade-in: start at full size but transparent
        entity.scale = .one  // Full size immediately
        
        // Set initial opacity through all children
        entity.children.forEach { child in
            if let model = child as? ModelEntity {
                model.model?.materials.forEach { material in
                    if var simpleMaterial = material as? SimpleMaterial {
                        // Start slightly visible to avoid pop-in
                        simpleMaterial.color.tint = simpleMaterial.color.tint.withAlphaComponent(0.7)
                    }
                }
            }
        }
    }
    
    private func cleanupOldAnchors(currentTexts: [TrackedText]) {
        // Only cleanup periodically to avoid performance impact
        let now = Date()
        guard now.timeIntervalSince(lastCleanupTime) >= cleanupInterval else { return }
        lastCleanupTime = now
        
        let anchorsCopy = activeAnchors
        let cameraTransform = arView?.cameraTransform.matrix
        
        for (key, anchor) in anchorsCopy {
            var shouldRemove = false
            var removalReason = ""
            
            // 1. Remove if too old
            if anchor.age > anchorCleanupAge {
                shouldRemove = true
                removalReason = "too old (\(String(format: "%.1f", anchor.age))s)"
            }
            
            // 2. Check distance from camera (if camera transform available)
            if !shouldRemove, let camTransform = cameraTransform, let anchorEntity = anchor.anchorEntity {
                let anchorPosition = anchorEntity.position(relativeTo: nil)
                let cameraPosition = SIMD3<Float>(
                    camTransform.columns.3.x,
                    camTransform.columns.3.y,
                    camTransform.columns.3.z
                )
                let distance = simd_distance(anchorPosition, cameraPosition)
                
                if distance > maxVisibleDistance {
                    shouldRemove = true
                    removalReason = "too far (\(String(format: "%.1f", distance))m)"
                }
                
                // 3. Check if in field of view (simplified check)
                if !shouldRemove && distance > 1.0 {  // Only check FOV for distant objects
                    let toAnchor = normalize(anchorPosition - cameraPosition)
                    let cameraForward = SIMD3<Float>(
                        -camTransform.columns.2.x,
                        -camTransform.columns.2.y,
                        -camTransform.columns.2.z
                    )
                    let angle = acos(dot(toAnchor, normalize(cameraForward))) * 180 / .pi
                    
                    if angle > fieldOfViewAngle {
                        shouldRemove = true
                        removalReason = "out of FOV (\(String(format: "%.0f", angle))°)"
                    }
                }
            }
            
            // 4. Quick removal for untracked texts
            if !shouldRemove && anchor.age > quickCleanupAge {
                // Check if still being tracked
                var found = false
                for tracked in currentTexts {
                    if textSimilarity(anchor.originalText, tracked.text) > 0.8 {
                        let dx = abs(Float(anchor.screenPosition.midX - tracked.boundingBox.midX))
                        let dy = abs(Float(anchor.screenPosition.midY - tracked.boundingBox.midY))
                        if dx < positionThreshold && dy < positionThreshold {
                            found = true
                            break
                        }
                    }
                }
                
                if !found {
                    shouldRemove = true
                    removalReason = "no longer tracked"
                }
            }
            
            if shouldRemove {
                Logger.shared.log(.debug, "AR3D: Removing anchor '\(anchor.originalText)' - \(removalReason)")
                anchor.anchorEntity?.removeFromParent()
                activeAnchors.removeValue(forKey: key)
            }
        }
    }
    
    private func cleanupOldestAnchors(keepCount: Int) {
        // Remove oldest anchors when limit exceeded
        let sortedAnchors = activeAnchors.sorted { $0.value.lastUpdated < $1.value.lastUpdated }
        let toRemove = sortedAnchors.count - keepCount
        
        if toRemove > 0 {
            for i in 0..<toRemove {
                let (key, anchor) = sortedAnchors[i]
                anchor.anchorEntity?.removeFromParent()
                activeAnchors.removeValue(forKey: key)
                Logger.shared.log(.debug, "AR3D: Removed oldest anchor: \(anchor.originalText)")
            }
        }
    }
    
    // Distance-based culling for performance
    func updateVisibility(cameraTransform: simd_float4x4) {
        let cameraPos = cameraTransform.columns.3.xyz
        
        for (_, anchor) in activeAnchors {
            guard let entity = anchor.anchorEntity else { continue }
            
            let distance = simd_distance(cameraPos, anchor.worldPosition)
            
            if distance > cullDistance {
                // Hide if too far
                entity.isEnabled = false
            } else if distance > fadeDistance {
                // Fade based on distance
                entity.isEnabled = true
                let fadeFactor = 1.0 - ((distance - fadeDistance) / (cullDistance - fadeDistance))
                entity.scale = .one * Float(fadeFactor)
            } else {
                // Full visibility
                entity.isEnabled = true
                entity.scale = .one
            }
        }
    }
    
    // MARK: - Helpers
    
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        return a + (b - a) * t
    }
    
    // MARK: - Debug Visualization
    
    private func addDebugVisualization(to arView: ARView) {
        // Add coordinate axes at origin
        let axisLength: Float = 0.1
        
        // X axis (red)
        let xAxisMesh = MeshResource.generateBox(size: [axisLength, 0.002, 0.002])
        var xMaterial = SimpleMaterial()
        xMaterial.color = .init(tint: .red)
        let xAxis = ModelEntity(mesh: xAxisMesh, materials: [xMaterial])
        xAxis.position = [axisLength/2, 0, 0]
        
        // Y axis (green)
        let yAxisMesh = MeshResource.generateBox(size: [0.002, axisLength, 0.002])
        var yMaterial = SimpleMaterial()
        yMaterial.color = .init(tint: .green)
        let yAxis = ModelEntity(mesh: yAxisMesh, materials: [yMaterial])
        yAxis.position = [0, axisLength/2, 0]
        
        // Z axis (blue)
        let zAxisMesh = MeshResource.generateBox(size: [0.002, 0.002, axisLength])
        var zMaterial = SimpleMaterial()
        zMaterial.color = .init(tint: .blue)
        let zAxis = ModelEntity(mesh: zAxisMesh, materials: [zMaterial])
        zAxis.position = [0, 0, -axisLength/2]
        
        // Create anchor for axes
        let debugAnchor = AnchorEntity(world: .zero)
        debugAnchor.name = "debug_axes"
        debugAnchor.addChild(xAxis)
        debugAnchor.addChild(yAxis)
        debugAnchor.addChild(zAxis)
        
        // Add grid plane at z = -1m for reference
        let gridSize: Float = 2.0
        let gridMesh = MeshResource.generatePlane(width: gridSize, height: gridSize)
        var gridMaterial = SimpleMaterial()
        gridMaterial.color = .init(tint: UIColor.white.withAlphaComponent(0.1))
        let gridEntity = ModelEntity(mesh: gridMesh, materials: [gridMaterial])
        gridEntity.position = SIMD3<Float>(0, 0, -1.0)
        
        let gridAnchor = AnchorEntity(world: gridEntity.position)
        gridAnchor.name = "debug_grid"
        gridAnchor.addChild(gridEntity)
        
        arView.scene.addAnchor(debugAnchor)
        arView.scene.addAnchor(gridAnchor)
        debugAnchors.append(debugAnchor)
        debugAnchors.append(gridAnchor)
        
        Logger.shared.log(.info, "AR3D: Debug visualization added (axes + grid)")
    }
    
    func toggleDebugMode() {
        debugMode.toggle()
        debugOverlayEnabled = debugMode
        
        if debugMode {
            if let arView = arView {
                addDebugVisualization(to: arView)
            }
        } else {
            // Remove debug anchors
            for anchor in debugAnchors {
                anchor.removeFromParent()
            }
            debugAnchors.removeAll()
        }
        
        Logger.shared.log(.info, "AR3D: Debug mode \(debugMode ? "enabled" : "disabled")")
    }
    
    /// Add debug corner markers for a bounding box
    private func addDebugCorners(for box: CGRect, worldPos: SIMD3<Float>, in arView: ARView) {
        guard debugOverlayEnabled else { return }
        
        // Create small spheres at the corners of the bounding box
        let cornerSize: Float = 0.005  // 5mm spheres
        let sphereMesh = MeshResource.generateSphere(radius: cornerSize)
        
        var material = SimpleMaterial()
        material.color = .init(tint: .systemYellow)
        
        // Calculate corner positions relative to world position
        let corners = [
            CGPoint(x: box.minX, y: box.minY),  // Bottom-left
            CGPoint(x: box.maxX, y: box.minY),  // Bottom-right
            CGPoint(x: box.maxX, y: box.maxY),  // Top-right
            CGPoint(x: box.minX, y: box.maxY)   // Top-left
        ]
        
        let cornerAnchor = AnchorEntity(world: worldPos)
        cornerAnchor.name = "debug_corners_\(box.hashValue)"
        
        for (index, corner) in corners.enumerated() {
            let sphere = ModelEntity(mesh: sphereMesh, materials: [material])
            // Offset from center based on normalized corner position
            let offsetX = Float((corner.x - box.midX) * 2.0) * 0.1
            let offsetY = Float((box.midY - corner.y) * 2.0) * 0.1
            sphere.position = SIMD3<Float>(offsetX, offsetY, 0)
            sphere.name = "corner_\(index)"
            cornerAnchor.addChild(sphere)
        }
        
        arView.scene.addAnchor(cornerAnchor)
        debugAnchors.append(cornerAnchor)
        
        // Auto-remove after 2 seconds to avoid clutter
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            cornerAnchor.removeFromParent()
            self?.debugAnchors.removeAll { $0 === cornerAnchor }
        }
    }
    
    /// Clear all anchors and reset state
    func clearAll() {
        // Remove all anchor entities from scene
        for (_, anchor) in activeAnchors {
            anchor.anchorEntity?.removeFromParent()
        }
        
        // Clear the dictionary
        activeAnchors.removeAll()
        
        // Clear position history for smoothing
        positionHistory.removeAll()
        
        // Remove debug anchors if any
        for anchor in debugAnchors {
            anchor.removeFromParent()
        }
        debugAnchors.removeAll()
        
        Logger.shared.log(.info, "AR3D: Cleared all anchors and state")
    }
}

// MARK: - Extensions

// The xyz property is already available in simd_float4